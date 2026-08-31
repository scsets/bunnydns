#!/usr/bin/env node

// Filename: mock_dns_bunny_node.mjs
// Description: Stateful Bunny API helper replacement for offline behavior tests.
// Author: SCS
// Copyright (C) 2026, SCS, all rights reserved.
// Created: 2026-08-30 Sun 00:00
// Version: 0.6.0
// Last-Updated: 2026-08-30 Sun 00:00
// Update #: 0

import { appendFile, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}
async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

async function writeJson(path, value) {
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

async function validateKey(path) {
  let key = await readFile(path, "utf8");
  if (key.endsWith("\n")) key = key.slice(0, -1);
  if (!key || key.includes("\n") || key.includes("\r")) {
    fail("Bunny API key file must contain exactly one line");
  }
  if (!/^[\x20-\x7e]+$/.test(key)) {
    fail("Bunny API key must contain printable ASCII characters only");
  }
  if (key.startsWith(" ") || key.endsWith(" ")) {
    fail("Bunny API key must not start or end with a space");
  }
}

function positiveInteger(value) {
  if (!/^[1-9][0-9]*$/.test(value)) fail("invalid identifier");
  return Number(value);
}

const argv = process.argv.slice(2);
if (argv.length < 4) fail("invalid mock helper invocation");
const [operation, keyFile] = argv;
const stateDirectory = process.env.MOCK_BUNNY_STATE;
if (!stateDirectory) fail("MOCK_BUNNY_STATE is required");
await validateKey(keyFile);

const zonePath = join(stateDirectory, "zone.json");
const requestLog = join(stateDirectory, "requests.log");
let zone = await readJson(zonePath);

async function log(method, path) {
  await appendFile(requestLog, `${method} https://api.bunny.net${path}\n`);
}

async function saveZone() {
  const temporaryPath = join(stateDirectory, `.zone.${process.pid}.json`);
  await writeJson(temporaryPath, zone);
  await rename(temporaryPath, zonePath);
}

switch (operation) {
  case "find-zone": {
    const [, , wantedZone, output] = argv;
    await log("GET", `/dnszone?search=${wantedZone}`);
    const items = zone.Domain.toLowerCase() === wantedZone.toLowerCase()
      ? [{ Id: zone.Id, Domain: zone.Domain }]
      : [];
    await writeJson(output, { Items: items });
    break;
  }
  case "fetch-zone": {
    const [, , zoneIdText, wantedZone, output] = argv;
    const zoneId = positiveInteger(zoneIdText);
    if (zoneId !== zone.Id || zone.Domain.toLowerCase() !== wantedZone.toLowerCase()) fail("not found");
    await log("GET", `/dnszone/${zoneId}`);
    await log("GET", `/dnszone/${zoneId}/records?page=1&perPage=1000`);
    await writeJson(output, zone);
    break;
  }
  case "add-record": {
    const [, , zoneIdText, bodyPath, output] = argv;
    const zoneId = positiveInteger(zoneIdText);
    if (zoneId !== zone.Id) fail("not found");
    await log("PUT", `/dnszone/${zoneId}/records`);
    const body = await readJson(bodyPath);
    const recordId = Math.max(0, ...zone.Records.map((record) => record.Id)) + 1;
    const record = {
      ...body,
      ...(Object.hasOwn(body, "AutoSslIssuance") ? {} : { AutoSslIssuance: true }),
      Id: recordId,
    };
    if (process.env.MOCK_BUNNY_ADD_VALUE_DRIFT) {
      record.Value = process.env.MOCK_BUNNY_ADD_VALUE_DRIFT;
    }
    zone.Records.push(record);
    await saveZone();
    await writeJson(output, record);
    break;
  }
  case "update-record": {
    const [, , zoneIdText, recordIdText, bodyPath, output] = argv;
    const zoneId = positiveInteger(zoneIdText);
    const recordId = positiveInteger(recordIdText);
    if (zoneId !== zone.Id) fail("not found");
    const index = zone.Records.findIndex((record) => record.Id === recordId);
    if (index < 0) fail("not found");
    await log("POST", `/dnszone/${zoneId}/records/${recordId}`);
    const body = await readJson(bodyPath);
    zone.Records[index] = { ...body, Id: recordId };
    await saveZone();
    await writeJson(output, zone.Records[index]);
    break;
  }
  case "delete-record": {
    const [, , zoneIdText, recordIdText, output] = argv;
    const zoneId = positiveInteger(zoneIdText);
    const recordId = positiveInteger(recordIdText);
    if (zoneId !== zone.Id) fail("not found");
    const index = zone.Records.findIndex((record) => record.Id === recordId);
    if (index < 0) fail("not found");
    await log("DELETE", `/dnszone/${zoneId}/records/${recordId}`);
    zone.Records.splice(index, 1);
    await saveZone();
    await writeJson(output, {});
    break;
  }
  default:
    fail(`unknown mock operation: ${operation}`);
}
