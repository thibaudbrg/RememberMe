// Trim a Google Directions response down to the exact allowlist the iOS client
// decodes. Everything not listed here is dropped so the proxy never relays
// addresses, place_ids, copyrights, fares, geocoded_waypoints, html_instructions,
// etc. The shape below must stay byte-compatible with the client's decoder.

export interface TrimmedDirections {
  status: string;
  error_message?: string;
  routes?: TrimmedRoute[];
}

interface TrimmedRoute {
  summary?: string;
  warnings?: string[];
  overview_polyline?: { points?: string };
  legs?: TrimmedLeg[];
}

interface TrimmedLeg {
  duration?: { value: number };
  distance?: { value: number };
  steps?: TrimmedStep[];
}

interface TrimmedStep {
  travel_mode?: string;
  polyline?: { points?: string };
  duration?: { value: number };
  distance?: { value: number };
  transit_details?: TrimmedTransitDetails;
}

interface TrimmedTransitDetails {
  line?: {
    name?: string;
    short_name?: string;
    vehicle?: { name?: string; type?: string };
  };
}

export function trimDirections(input: unknown): TrimmedDirections {
  const root = asRecord(input);
  const out: TrimmedDirections = {
    status: typeof root["status"] === "string" ? (root["status"] as string) : "UNKNOWN_ERROR",
  };

  const errMsg = root["error_message"];
  if (typeof errMsg === "string") out.error_message = errMsg;

  const routes = root["routes"];
  if (Array.isArray(routes)) {
    out.routes = routes.map(trimRoute);
  }

  return out;
}

function trimRoute(input: unknown): TrimmedRoute {
  const r = asRecord(input);
  const out: TrimmedRoute = {};

  if (typeof r["summary"] === "string") out.summary = r["summary"] as string;

  const warnings = r["warnings"];
  if (Array.isArray(warnings)) {
    out.warnings = warnings.filter((w): w is string => typeof w === "string");
  }

  const points = asRecord(r["overview_polyline"])["points"];
  if (typeof points === "string") out.overview_polyline = { points };

  const legs = r["legs"];
  if (Array.isArray(legs)) out.legs = legs.map(trimLeg);

  return out;
}

function trimLeg(input: unknown): TrimmedLeg {
  const l = asRecord(input);
  const out: TrimmedLeg = {};

  const dur = numValue(l["duration"]);
  if (dur !== undefined) out.duration = { value: dur };
  const dist = numValue(l["distance"]);
  if (dist !== undefined) out.distance = { value: dist };

  const steps = l["steps"];
  if (Array.isArray(steps)) out.steps = steps.map(trimStep);

  return out;
}

function trimStep(input: unknown): TrimmedStep {
  const s = asRecord(input);
  const out: TrimmedStep = {};

  if (typeof s["travel_mode"] === "string") out.travel_mode = s["travel_mode"] as string;

  const points = asRecord(s["polyline"])["points"];
  if (typeof points === "string") out.polyline = { points };

  const dur = numValue(s["duration"]);
  if (dur !== undefined) out.duration = { value: dur };
  const dist = numValue(s["distance"]);
  if (dist !== undefined) out.distance = { value: dist };

  const transit = trimTransit(s["transit_details"]);
  if (transit) out.transit_details = transit;

  return out;
}

function trimTransit(input: unknown): TrimmedTransitDetails | undefined {
  if (input === undefined || input === null) return undefined;
  const t = asRecord(input);
  const line = asRecord(t["line"]);

  const outLine: NonNullable<TrimmedTransitDetails["line"]> = {};
  if (typeof line["name"] === "string") outLine.name = line["name"] as string;
  if (typeof line["short_name"] === "string") outLine.short_name = line["short_name"] as string;

  const vehicle = asRecord(line["vehicle"]);
  const v: { name?: string; type?: string } = {};
  if (typeof vehicle["name"] === "string") v.name = vehicle["name"] as string;
  if (typeof vehicle["type"] === "string") v.type = vehicle["type"] as string;
  if (v.name !== undefined || v.type !== undefined) outLine.vehicle = v;

  if (Object.keys(outLine).length === 0) return undefined;
  return { line: outLine };
}

// Google's duration/distance objects are { text, value }; keep only `value`.
function numValue(input: unknown): number | undefined {
  const v = asRecord(input)["value"];
  return typeof v === "number" ? v : undefined;
}

function asRecord(input: unknown): Record<string, unknown> {
  return typeof input === "object" && input !== null ? (input as Record<string, unknown>) : {};
}
