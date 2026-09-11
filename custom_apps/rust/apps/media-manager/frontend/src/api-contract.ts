import { contract } from "./api-contract.generated";

type Schema =
  | boolean
  | {
      $ref?: string;
      type?: string | string[];
      nullable?: boolean;
      required?: string[];
      properties?: Record<string, Schema>;
      additionalProperties?: Schema;
      items?: Schema;
      enum?: unknown[];
      const?: unknown;
      allOf?: Schema[];
      anyOf?: Schema[];
      oneOf?: Schema[];
      minimum?: number;
      maximum?: number;
      minLength?: number;
      maxLength?: number;
      minItems?: number;
      maxItems?: number;
      pattern?: string;
    };
const definition = contract as {
  components: { schemas: Record<string, Schema> };
  responses: Array<{
    path: string;
    method: string;
    status: string;
    schema: Schema;
  }>;
};

export function matchesSchema(
  value: unknown,
  schema: Schema,
  depth = 0,
): boolean {
  if (depth > 64 || schema === false) return false;
  if (schema === true) return true;
  const matches = (child: unknown, spec: Schema) =>
    matchesSchema(child, spec, depth + 1);
  if (schema.$ref) {
    const target = definition.components.schemas[schema.$ref.split("/").pop()!];
    return target !== undefined && matches(value, target);
  }
  if (value === null && schema.nullable) return true;
  if (schema.allOf && !schema.allOf.every((part) => matches(value, part)))
    return false;
  if (schema.anyOf && !schema.anyOf.some((part) => matches(value, part)))
    return false;
  if (
    schema.oneOf &&
    schema.oneOf.filter((part) => matches(value, part)).length !== 1
  )
    return false;
  if ("const" in schema && value !== schema.const) return false;
  if (schema.enum && !schema.enum.includes(value)) return false;
  const types = schema.type ? [schema.type].flat() : [];
  const kind =
    value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
  if (
    types.length &&
    !types.some(
      (type) =>
        type === kind ||
        (type === "integer" &&
          typeof value === "number" &&
          Number.isInteger(value)),
    )
  )
    return false;
  if (typeof value === "number")
    return (
      Number.isFinite(value) &&
      (schema.minimum === undefined || value >= schema.minimum) &&
      (schema.maximum === undefined || value <= schema.maximum)
    );
  if (typeof value === "string")
    return (
      (schema.minLength === undefined || value.length >= schema.minLength) &&
      (schema.maxLength === undefined || value.length <= schema.maxLength) &&
      (!schema.pattern || new RegExp(schema.pattern).test(value))
    );
  if (Array.isArray(value))
    return (
      (schema.minItems === undefined || value.length >= schema.minItems) &&
      (schema.maxItems === undefined || value.length <= schema.maxItems) &&
      (!schema.items || value.every((entry) => matches(entry, schema.items!)))
    );
  if (value !== null && typeof value === "object") {
    const object = value as Record<string, unknown>;
    if (schema.required?.some((key) => !Object.hasOwn(object, key)))
      return false;
    return Object.entries(object).every(([key, entry]) => {
      const child = schema.properties?.[key];
      return child !== undefined
        ? matches(entry, child)
        : schema.additionalProperties === undefined ||
            matches(entry, schema.additionalProperties);
    });
  }
  return true;
}

export function validateApiResponse(
  path: string,
  method: string,
  status: number,
  value: unknown,
): boolean {
  const segments = new URL(path, "http://contract.invalid").pathname.split("/");
  const response = definition.responses.find(
    (entry) =>
      entry.method === method.toUpperCase() &&
      entry.status === String(status) &&
      (() => {
        const expected = entry.path.split("/");
        return (
          expected.length === segments.length &&
          expected.every(
            (part, index) =>
              part === segments[index] ||
              (part.startsWith("{") &&
                part.endsWith("}") &&
                segments[index] !== ""),
          )
        );
      })(),
  );
  return response !== undefined && matchesSchema(value, response.schema);
}
