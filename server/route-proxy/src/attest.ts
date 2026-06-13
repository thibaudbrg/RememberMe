// Apple App Attest verification — hand-rolled on WebCrypto + @peculiar/x509.
//
// Why hand-rolled and not `node-app-attest`: that package relies on
// `crypto.X509Certificate` / `crypto.createVerify` and the `cbor` (Node-stream)
// package, none of which run on Cloudflare Workers even with `nodejs_compat`.
// @peculiar/x509 is built directly on the WebCrypto API (the global `crypto`
// that Workers provides), and `cbor-x` is a pure-JS CBOR codec. We use
// `crypto.subtle` for all hashing and ECDSA verification.
//
// Apple reference:
// https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server

import * as x509 from "@peculiar/x509";
import { AsnParser } from "@peculiar/asn1-schema";
import { SubjectPublicKeyInfo } from "@peculiar/asn1-x509";
import { decode as cborDecode } from "cbor-x";

// Bind @peculiar/x509 to the Workers-provided WebCrypto implementation.
x509.cryptoProvider.set(crypto as unknown as Crypto);

// Apple App Attest Root CA G1 — pinned. Source:
// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
const APPLE_APP_ATTEST_ROOT_CA_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

const APPLE_ROOT = new x509.X509Certificate(APPLE_APP_ATTEST_ROOT_CA_PEM);

// credCert extension holding SHA256(authData ‖ clientDataHash).
const OID_APP_ATTEST_NONCE = "1.2.840.113635.100.8.2";

// aaguid markers (16 bytes) in authData.
const AAGUID_PROD = strToBytes("appattest"); // followed by seven 0x00
const AAGUID_DEVELOP = strToBytes("appattestdevelop");

export type AppAttestEnv = "production" | "development";

export interface VerifiedKey {
  // Raw SubjectPublicKeyInfo (SPKI) DER of the attested P-256 key, base64.
  publicKeySpkiB64: string;
}

/** Thrown for any verification failure. Message carries only a generic code (no PII). */
export class AttestError extends Error {}

// ---------------------------------------------------------------------------
// Attestation (initial enrollment)
// ---------------------------------------------------------------------------

export interface VerifyAttestationParams {
  attestation: Uint8Array; // raw CBOR attestation object
  challengeBytes: Uint8Array; // the exact challenge bytes (decoded from KV base64)
  keyId: string; // base64 keyId supplied by the client
  teamId: string;
  bundleId: string;
  env: AppAttestEnv;
}

interface DecodedAttestation {
  fmt: string;
  attStmt: { x5c: Uint8Array[]; receipt: Uint8Array };
  authData: Uint8Array;
}

export async function verifyAttestation(p: VerifyAttestationParams): Promise<VerifiedKey> {
  const decoded = decodeAttestationObject(p.attestation);

  if (decoded.fmt !== "apple-appattest") throw new AttestError("bad_fmt");
  const x5c = decoded.attStmt.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 2) throw new AttestError("bad_x5c");

  const credCert = new x509.X509Certificate(toBuf(x5c[0]!));
  const intermediate = new x509.X509Certificate(toBuf(x5c[1]!));

  // 1. Verify the chain: credCert <- intermediate <- Apple root (signatures only;
  //    App Attest certs are short-lived and Apple does not intend expiry checks here).
  if (!(await intermediate.verify({ publicKey: APPLE_ROOT.publicKey, signatureOnly: true }))) {
    throw new AttestError("intermediate_not_signed_by_root");
  }
  if (!(await credCert.verify({ publicKey: intermediate.publicKey, signatureOnly: true }))) {
    throw new AttestError("credcert_not_signed_by_intermediate");
  }

  // 2/3. nonce = SHA256(authData ‖ clientDataHash), clientDataHash = SHA256(challenge).
  const clientDataHash = await sha256(p.challengeBytes);
  const expectedNonce = await sha256(concat(decoded.authData, clientDataHash));

  // 4. Extract nonce from credCert extension OID 1.2.840.113635.100.8.2.
  const ext = credCert.getExtension(OID_APP_ATTEST_NONCE);
  if (!ext) throw new AttestError("missing_nonce_ext");
  const actualNonce = extractNonceOctetString(new Uint8Array(ext.value));
  if (!bytesEqual(actualNonce, expectedNonce)) throw new AttestError("nonce_mismatch");

  // 5. keyId = base64(SHA256(raw EC public key)). Apple hashes the raw key point
  //    (the SPKI's subjectPublicKey BIT STRING contents), not the whole SPKI.
  const spki = new Uint8Array(credCert.publicKey.rawData);
  const spkiParsed = AsnParser.parse(spki, SubjectPublicKeyInfo);
  const rawPubKey = new Uint8Array(spkiParsed.subjectPublicKey);
  const computedKeyId = b64encode(await sha256(rawPubKey));
  if (computedKeyId !== p.keyId) throw new AttestError("keyid_mismatch");

  // 6. rpIdHash (authData[0..32]) === SHA256(teamId.bundleId).
  const appId = `${p.teamId}.${p.bundleId}`;
  const expectedRpIdHash = await sha256(strToBytes(appId));
  if (!bytesEqual(decoded.authData.subarray(0, 32), expectedRpIdHash)) {
    throw new AttestError("rpid_mismatch");
  }

  // 7. counter (authData[33..37]) === 0.
  const counter = readUint32BE(decoded.authData, 33);
  if (counter !== 0) throw new AttestError("counter_not_zero");

  // 8. aaguid (authData[37..53]) matches the configured environment.
  const aaguid = decoded.authData.subarray(37, 53);
  if (p.env === "production") {
    if (!aaguidEquals(aaguid, AAGUID_PROD, 9)) throw new AttestError("aaguid_not_prod");
  } else {
    if (!bytesEqual(aaguid, AAGUID_DEVELOP)) throw new AttestError("aaguid_not_develop");
  }

  // 9. credentialId (authData) === keyId.
  const credIdLen = readUint16BE(decoded.authData, 53);
  const credId = decoded.authData.subarray(55, 55 + credIdLen);
  if (b64encode(credId) !== p.keyId) throw new AttestError("credid_mismatch");

  return { publicKeySpkiB64: b64encode(spki) };
}

function decodeAttestationObject(raw: Uint8Array): DecodedAttestation {
  let obj: unknown;
  try {
    obj = cborDecode(raw);
  } catch {
    throw new AttestError("cbor_decode_failed");
  }
  if (!isRecord(obj)) throw new AttestError("bad_attestation");
  const fmt = obj["fmt"];
  const attStmt = obj["attStmt"];
  const authData = obj["authData"];
  if (typeof fmt !== "string" || !isRecord(attStmt) || !isBytes(authData)) {
    throw new AttestError("bad_attestation");
  }
  const x5c = attStmt["x5c"];
  const receipt = attStmt["receipt"];
  if (!Array.isArray(x5c) || !x5c.every(isBytes) || !isBytes(receipt)) {
    throw new AttestError("bad_attestation");
  }
  return {
    fmt,
    attStmt: { x5c: x5c as Uint8Array[], receipt: receipt as Uint8Array },
    authData: toU8(authData),
  };
}

// The nonce extension value is DER: SEQUENCE { [1] EXPLICIT { OCTET STRING (32 bytes) } }.
// Walk the DER and return the first 32-byte OCTET STRING (tag 0x04). Robust to the
// exact nesting without pulling a full ASN.1 schema.
function extractNonceOctetString(der: Uint8Array): Uint8Array {
  let i = 0;
  while (i < der.length) {
    const tag = der[i]!;
    i += 1;
    if (i >= der.length) break;
    let len = der[i]!;
    i += 1;
    if (len & 0x80) {
      const n = len & 0x7f;
      len = 0;
      for (let k = 0; k < n; k++) {
        if (i >= der.length) throw new AttestError("nonce_parse_failed");
        len = (len << 8) | der[i]!;
        i += 1;
      }
    }
    // Constructed (0x20 bit set) — descend into the contents.
    if (tag & 0x20) continue;
    if (tag === 0x04 && len === 32) {
      return der.subarray(i, i + 32);
    }
    i += len; // primitive, non-target — skip its value
  }
  throw new AttestError("nonce_parse_failed");
}

// ---------------------------------------------------------------------------
// Assertion (per-request, on /v1/route)
// ---------------------------------------------------------------------------

export interface VerifyAssertionParams {
  assertion: Uint8Array; // raw CBOR { signature, authenticatorData }
  rawBody: Uint8Array; // exact bytes of the /v1/route request body
  publicKeySpkiB64: string; // stored SPKI
  teamId: string;
  bundleId: string;
  storedCounter: number;
}

export interface AssertionResult {
  newCounter: number;
}

export async function verifyAssertion(p: VerifyAssertionParams): Promise<AssertionResult> {
  let decoded: unknown;
  try {
    decoded = cborDecode(p.assertion);
  } catch {
    throw new AttestError("assertion_cbor_failed");
  }
  if (!isRecord(decoded)) throw new AttestError("bad_assertion");
  const signature = decoded["signature"];
  const authenticatorData = decoded["authenticatorData"];
  if (!isBytes(signature) || !isBytes(authenticatorData)) throw new AttestError("bad_assertion");
  const sig = toU8(signature);
  const authData = toU8(authenticatorData);

  // nonce = SHA256(authenticatorData ‖ SHA256(rawBody)).
  const clientDataHash = await sha256(p.rawBody);
  const nonce = await sha256(concat(authData, clientDataHash));

  // Verify ECDSA P-256 signature (DER-encoded) over the nonce with the stored key.
  const key = await crypto.subtle.importKey(
    "spki",
    toBuf(b64decode(p.publicKeySpkiB64)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const sigRaw = derToRawEcdsaSig(sig);
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    toBuf(sigRaw),
    toBuf(nonce),
  );
  if (!ok) throw new AttestError("bad_signature");

  // rpIdHash check.
  const expectedRpIdHash = await sha256(strToBytes(`${p.teamId}.${p.bundleId}`));
  if (!bytesEqual(authData.subarray(0, 32), expectedRpIdHash)) throw new AttestError("rpid_mismatch");

  // counter must be strictly greater than the stored value.
  const counter = readUint32BE(authData, 33);
  if (counter <= p.storedCounter) throw new AttestError("counter_not_advanced");

  return { newCounter: counter };
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest("SHA-256", toBuf(data));
  return new Uint8Array(digest);
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

// Compare the first `prefixLen` bytes of aaguid to marker, and require the rest to be 0x00.
function aaguidEquals(aaguid: Uint8Array, marker: Uint8Array, prefixLen: number): boolean {
  if (aaguid.length !== 16) return false;
  for (let i = 0; i < prefixLen; i++) if (aaguid[i] !== marker[i]) return false;
  for (let i = prefixLen; i < 16; i++) if (aaguid[i] !== 0) return false;
  return true;
}

function readUint32BE(buf: Uint8Array, offset: number): number {
  return (
    ((buf[offset]! << 24) | (buf[offset + 1]! << 16) | (buf[offset + 2]! << 8) | buf[offset + 3]!) >>> 0
  );
}

function readUint16BE(buf: Uint8Array, offset: number): number {
  return ((buf[offset]! << 8) | buf[offset + 1]!) & 0xffff;
}

// Convert a DER-encoded ECDSA signature (SEQUENCE{ INTEGER r, INTEGER s }) to the
// raw r||s (64-byte) form WebCrypto expects.
function derToRawEcdsaSig(der: Uint8Array): Uint8Array {
  if (der[0] !== 0x30) throw new AttestError("bad_sig_der");
  let i = 2;
  if (der[1]! & 0x80) i = 2 + (der[1]! & 0x7f); // skip long-form SEQUENCE length
  const readInt = (): Uint8Array => {
    if (der[i] !== 0x02) throw new AttestError("bad_sig_der");
    const len = der[i + 1]!;
    let start = i + 2;
    let end = start + len;
    // strip leading zero padding
    while (start < end - 1 && der[start] === 0x00) start += 1;
    i = end;
    return der.subarray(start, end);
  };
  const r = readInt();
  const s = readInt();
  const out = new Uint8Array(64);
  out.set(r, 32 - r.length);
  out.set(s, 64 - s.length);
  return out;
}

function strToBytes(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}

function isBytes(v: unknown): v is Uint8Array {
  return v instanceof Uint8Array;
}

function toU8(v: Uint8Array): Uint8Array {
  return v;
}

// Produce a standalone ArrayBuffer view that satisfies BufferSource without
// SharedArrayBuffer ambiguity.
function toBuf(u8: Uint8Array): ArrayBuffer {
  const ab = new ArrayBuffer(u8.byteLength);
  new Uint8Array(ab).set(u8);
  return ab;
}

export function b64encode(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]!);
  return btoa(bin);
}

export function b64decode(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
