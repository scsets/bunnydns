#!/usr/bin/env node

// Filename: dns_bunny_node.mjs
// Description: Call the Bunny API for dns_bunny.sh through Bunny's official client.
// Author: SCS
// Copyright (C) 2026, SCS, all rights reserved.
// Created: 2026-08-30 Sun 00:00
// Version: 0.6.0
// Last-Updated: 2026-08-30 Sun 00:00
// Update #: 1

import { readFile, writeFile } from "node:fs/promises";

const PROGRAM = "dns_bunny_node.mjs";
const VERSION = "0.6.0";
const PAGE_SIZE = 1000;
const REQUEST_TIMEOUT_MS = 60_000;

function usage() {
  process.stdout.write(`${PROGRAM} ${VERSION}\n`);
  process.stdout.write(`Usage:
  ${PROGRAM} version
  ${PROGRAM} runtime-check
  ${PROGRAM} find-zone KEY_FILE ZONE OUTPUT
  ${PROGRAM} fetch-zone KEY_FILE ZONE_ID ZONE OUTPUT
  ${PROGRAM} add-record KEY_FILE ZONE_ID BODY OUTPUT
  ${PROGRAM} update-record KEY_FILE ZONE_ID RECORD_ID BODY OUTPUT
  ${PROGRAM} delete-record KEY_FILE ZONE_ID RECORD_ID OUTPUT
`);
}

function fail(message) {
  throw new Error(message);
}

function positiveInteger(value, label) {
  if (!/^[1-9][0-9]*$/.test(value)) {
    fail(`${label} must be a positive integer`);
  }
  const result = Number(value);
  if (!Number.isSafeInteger(result)) {
    fail(`${label} is too large`);
  }
  return result;
}

async function readApiKey(path) {
  let value;
  try {
    value = await readFile(path, "utf8");
  } catch (error) {
    fail(`cannot read Bunny API key file: ${error.message}`);
  }
  if (value.endsWith("\n")) {
    value = value.slice(0, -1);
  }
  if (value.length === 0) {
    fail("Bunny API key is empty");
  }
  if (value.includes("\n") || value.includes("\r")) {
    fail("Bunny API key file must contain exactly one line");
  }
  if (!/^[\x20-\x7e]+$/.test(value)) {
    fail("Bunny API key must contain printable ASCII characters only");
  }
  if (value.startsWith(" ") || value.endsWith(" ")) {
    fail("Bunny API key must not start or end with a space");
  }
  return value;
}

async function readJson(path) {
  let text;
  try {
    text = await readFile(path, "utf8");
  } catch (error) {
    fail(`cannot read request body: ${error.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    fail(`request body is not valid JSON: ${error.message}`);
  }
}

async function writeJson(path, value) {
  try {
    await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
  } catch (error) {
    fail(`cannot write Bunny API response: ${error.message}`);
  }
}

function requestSignal() {
  return AbortSignal.timeout(REQUEST_TIMEOUT_MS);
}

function requirePage(data, page, label) {
  if (
    data === null ||
    typeof data !== "object" ||
    !Array.isArray(data.Items) ||
    data.CurrentPage !== page ||
    !Number.isInteger(data.TotalItems) ||
    data.TotalItems < 0 ||
    typeof data.HasMoreItems !== "boolean"
  ) {
    fail(`Bunny returned an invalid ${label} page`);
  }
}

async function collectPages(getPage, label) {
  const items = [];
  let page = 1;
  let totalItems;
  while (true) {
    const data = await getPage(page);
    requirePage(data, page, label);
    if (totalItems === undefined) {
      totalItems = data.TotalItems;
    } else if (data.TotalItems !== totalItems) {
      fail(`Bunny ${label}s changed while they were being read; retry`);
    }
    items.push(...data.Items);
    if (!data.HasMoreItems) {
      break;
    }
    if (data.Items.length === 0) {
      fail(`Bunny ${label} pagination made no progress`);
    }
    page += 1;
  }
  if (items.length !== totalItems) {
    fail(`Bunny ${label} pages were incomplete; retry`);
  }
  return items;
}

function requireData(result) {
  if (result.error !== undefined) {
    const message = result.error?.Message ?? result.error?.ErrorKey ?? "Bunny API returned an error";
    const status = result.response?.status;
    fail(status ? `${message} (HTTP ${status})` : message);
  }
  if (result.data === undefined) {
    fail("Bunny API returned no response document");
  }
  return result.data;
}

async function loadClientModule() {
  let module;
  try {
    module = await import("@bunny.net/openapi-client");
  } catch (error) {
    fail(`cannot load @bunny.net/openapi-client: ${error.message}`);
  }
  if (typeof module.createCoreClient !== "function") {
    fail("@bunny.net/openapi-client does not export createCoreClient");
  }
  return module;
}

async function createClient(keyFile) {
  const apiKey = await readApiKey(keyFile);
  const module = await loadClientModule();
  return module.createCoreClient({
    apiKey,
    userAgent: `${PROGRAM}/${VERSION}`,
  });
}

async function findZone(client, zone, output) {
  const zones = await collectPages(async (page) => {
    const result = await client.GET("/dnszone", {
      params: { query: { page, perPage: PAGE_SIZE, search: zone, view: 0 } },
      signal: requestSignal(),
    });
    return requireData(result);
  }, "zone list");
  const wanted = zone.toLowerCase();
  const matches = zones.filter(
    (candidate) => typeof candidate.Domain === "string" && candidate.Domain.toLowerCase() === wanted,
  );
  await writeJson(output, { Items: matches });
}

async function fetchZone(client, zoneId, zone, output) {
  const zoneResult = await client.GET("/dnszone/{id}", {
    params: { path: { id: zoneId } },
    signal: requestSignal(),
  });
  const document = requireData(zoneResult);
  if (typeof document.Domain !== "string" || document.Domain.toLowerCase() !== zone.toLowerCase()) {
    fail("Bunny returned an invalid zone document");
  }

  const records = await collectPages(async (page) => {
    const result = await client.GET("/dnszone/{zoneId}/records", {
      params: {
        path: { zoneId },
        query: { page, perPage: PAGE_SIZE },
      },
      signal: requestSignal(),
    });
    return requireData(result);
  }, "DNS record list");

  const ids = new Set();
  for (const record of records) {
    if (!Number.isInteger(record.Id) || record.Id <= 0 || ids.has(record.Id)) {
      fail("Bunny returned duplicate or invalid DNS record IDs");
    }
    ids.add(record.Id);
  }
  await writeJson(output, { ...document, Records: records });
}

async function addRecord(client, zoneId, bodyFile, output) {
  const body = await readJson(bodyFile);
  const result = await client.PUT("/dnszone/{zoneId}/records", {
    params: { path: { zoneId } },
    body,
    signal: requestSignal(),
  });
  await writeJson(output, requireData(result));
}

async function updateRecord(client, zoneId, recordId, bodyFile, output) {
  const body = await readJson(bodyFile);
  const result = await client.POST("/dnszone/{zoneId}/records/{id}", {
    params: { path: { zoneId, id: recordId } },
    body,
    signal: requestSignal(),
  });
  if (result.error !== undefined) {
    requireData(result);
  }
  await writeJson(output, result.data ?? {});
}

async function deleteRecord(client, zoneId, recordId, output) {
  const result = await client.DELETE("/dnszone/{zoneId}/records/{id}", {
    params: { path: { zoneId, id: recordId } },
    signal: requestSignal(),
  });
  if (result.error !== undefined) {
    requireData(result);
  }
  await writeJson(output, result.data ?? {});
}

async function main(argv) {
  if (argv.length === 0) {
    usage();
    return;
  }
  if (argv[0] === "version") {
    if (argv.length !== 1) fail("version takes no arguments");
    process.stdout.write(`${PROGRAM} ${VERSION}\n`);
    return;
  }
  if (argv[0] === "runtime-check") {
    if (argv.length !== 1) fail("runtime-check takes no arguments");
    await loadClientModule();
    process.stdout.write("Official Bunny client runtime is available.\n");
    return;
  }

  const operation = argv[0];
  const expected = {
    "find-zone": 4,
    "fetch-zone": 5,
    "add-record": 5,
    "update-record": 6,
    "delete-record": 5,
  }[operation];
  if (expected === undefined) {
    fail(`unknown operation: ${operation}`);
  }
  if (argv.length !== expected) {
    fail(`incorrect arguments for ${operation}`);
  }

  const keyFile = argv[1];
  const client = await createClient(keyFile);
  switch (operation) {
    case "find-zone":
      await findZone(client, argv[2], argv[3]);
      break;
    case "fetch-zone":
      await fetchZone(client, positiveInteger(argv[2], "zone ID"), argv[3], argv[4]);
      break;
    case "add-record":
      await addRecord(client, positiveInteger(argv[2], "zone ID"), argv[3], argv[4]);
      break;
    case "update-record":
      await updateRecord(
        client,
        positiveInteger(argv[2], "zone ID"),
        positiveInteger(argv[3], "record ID"),
        argv[4],
        argv[5],
      );
      break;
    case "delete-record":
      await deleteRecord(
        client,
        positiveInteger(argv[2], "zone ID"),
        positiveInteger(argv[3], "record ID"),
        argv[4],
      );
      break;
  }
}

try {
  await main(process.argv.slice(2));
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}
