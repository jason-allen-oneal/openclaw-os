import assert from "node:assert/strict";
import test from "node:test";
import {
  APPLIANCE_API_VERSION,
  ContractValidationError,
  createHostdRequest,
  parseHostdRequest,
  parseHostdResponse,
} from "../../packages/appliance-contracts/src/index.ts";

test("hostd contracts accept only fixed operations and exact fields", () => {
  assert.deepEqual(createHostdRequest("request-1", "system.status"), {
    version: APPLIANCE_API_VERSION,
    id: "request-1",
    operation: "system.status",
    params: {},
  });

  assert.throws(
    () =>
      parseHostdRequest({
        version: APPLIANCE_API_VERSION,
        id: "request-2",
        operation: "exec",
        params: { command: "id" },
      }),
    (error: unknown) =>
      error instanceof ContractValidationError && error.code === "UNSUPPORTED_OPERATION",
  );

  assert.throws(() =>
    parseHostdRequest({
      version: APPLIANCE_API_VERSION,
      id: "request-3",
      operation: "service.status",
      params: { unit: "ssh.service" },
    }),
  );

  assert.throws(() =>
    parseHostdRequest({
      version: APPLIANCE_API_VERSION,
      id: "request-4",
      operation: "system.status",
      params: {},
      extra: true,
    }),
  );
});


test("hostd response validation is bound to the original request", () => {
  const request = createHostdRequest("request-5", "service.status", {
    unit: "openclaw.service",
  });

  assert.throws(() =>
    parseHostdResponse(
      {
        version: APPLIANCE_API_VERSION,
        id: request.id,
        ok: true,
        result: {
          unit: "openclaw-controller.service",
          loadState: "loaded",
          activeState: "active",
          subState: "running",
          unitFileState: "enabled",
          mainPid: 1,
          execMainStatus: 0,
        },
      },
      request,
    ),
  );
});
