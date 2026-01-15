#!/usr/bin/env node
import fs from "fs";
import path from "path";

const root = path.resolve("PresetsSource");
const outDir = path.resolve("Chromastage/Resources/Presets");
const outFile = path.join(outDir, "presets.json");

const files = fs
  .readdirSync(root)
  .filter((file) => file.endsWith(".json"))
  .sort((a, b) => a.localeCompare(b));

const presets = files.map((file) => {
  const fullPath = path.join(root, file);
  const raw = fs.readFileSync(fullPath, "utf8");
  const data = JSON.parse(raw);
  return {
    name: path.basename(file, ".json"),
    ...data,
  };
});

const payload = {
  version: 1,
  count: presets.length,
  presets,
};

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(payload));
console.log(`Wrote ${payload.count} presets to ${outFile}`);
