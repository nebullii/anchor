// Minimal argument validation for tool inputSchemas (object with typed
// properties). Coerces numeric strings to integers because agents often
// pass ids as strings. Returns { args, errors }.

export function validateArgs(schema, input) {
  const errors = [];
  const args = {};
  const raw = input ?? {};

  if (typeof raw !== "object" || Array.isArray(raw)) {
    return { args, errors: ["arguments must be an object"] };
  }

  const props = schema.properties || {};
  for (const key of schema.required || []) {
    if (raw[key] === undefined || raw[key] === null) errors.push(`${key} is required`);
  }
  if (schema.additionalProperties === false) {
    for (const key of Object.keys(raw)) if (!(key in props)) errors.push(`${key} is not a known argument`);
  }

  for (const [key, spec] of Object.entries(props)) {
    let value = raw[key];
    if (value === undefined || value === null) continue;

    if (Array.isArray(spec.type)) {
      // Union of integer and string (e.g. project id or slug).
      if (typeof value === "string" && /^\d+$/.test(value)) value = Number(value);
      if (Number.isInteger(value) && spec.type.includes("integer")) {
        if (spec.minimum !== undefined && value < spec.minimum) errors.push(`${key} must be >= ${spec.minimum}`);
      } else if (typeof value === "string" && spec.type.includes("string") && value.length > 0) {
        if (spec.pattern && !new RegExp(spec.pattern).test(value)) errors.push(`${key} must match ${spec.pattern}`);
      } else {
        errors.push(`${key} must be one of: ${spec.type.join(", ")}`);
        continue;
      }
      args[key] = value;
      continue;
    }

    switch (spec.type) {
      case "integer":
        if (typeof value === "string" && /^\d+$/.test(value)) value = Number(value);
        if (!Number.isInteger(value)) { errors.push(`${key} must be an integer`); continue; }
        if (spec.minimum !== undefined && value < spec.minimum) errors.push(`${key} must be >= ${spec.minimum}`);
        if (spec.maximum !== undefined && value > spec.maximum) errors.push(`${key} must be <= ${spec.maximum}`);
        break;
      case "string":
        if (typeof value !== "string") { errors.push(`${key} must be a string`); continue; }
        if (spec.minLength !== undefined && value.length < spec.minLength) errors.push(`${key} is too short`);
        if (spec.maxLength !== undefined && value.length > spec.maxLength) errors.push(`${key} is too long`);
        if (spec.pattern && !new RegExp(spec.pattern).test(value)) errors.push(`${key} must match ${spec.pattern}`);
        break;
      case "boolean":
        if (typeof value !== "boolean") { errors.push(`${key} must be a boolean`); continue; }
        break;
      default:
        break;
    }
    args[key] = value;
  }

  return { args, errors };
}
