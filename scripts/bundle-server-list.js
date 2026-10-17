"use strict";

const fs = require("fs");
const path = require("path");

const rootDir = path.join(__dirname, "..");
const destPath = path.join(rootDir, "configs", "server_list_compressed");

// The repository ships a server list snapshot at configs/server_list_compressed.
// A developer can override the source with PSIPHON_SERVER_LIST (explicit file)
// or PSIPHON_CONFIG_DIR (a psiphon-cache style directory) to bundle a fresher
// list — the same env contract the Forough Linux client uses.

function resolveDownloadFilename(configDir) {
  const configPath = path.join(configDir, "psiphon.config");
  if (!fs.existsSync(configPath)) {
    return "remote_server_list";
  }

  try {
    const cfg = JSON.parse(fs.readFileSync(configPath, "utf-8"));
    return cfg.RemoteServerListDownloadFilename || "remote_server_list";
  } catch {
    return "remote_server_list";
  }
}

function findSource() {
  const repoOnly = process.argv.includes("--repo-only");

  if (repoOnly && fs.existsSync(destPath)) {
    return destPath;
  }

  const explicit = process.env.PSIPHON_SERVER_LIST?.trim();
  if (explicit) {
    if (fs.existsSync(explicit)) {
      return explicit;
    }
    console.warn(`PSIPHON_SERVER_LIST is set but file not found: ${explicit}`);
  }

  const configDir = process.env.PSIPHON_CONFIG_DIR?.trim() || "";
  if (configDir) {
    const filename = resolveDownloadFilename(configDir);
    const candidates = [
      path.join(configDir, filename),
      path.join(configDir, "server_list_compressed"),
      path.join(configDir, "remote_server_list"),
    ];
    for (const candidate of candidates) {
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }

  if (fs.existsSync(destPath)) {
    return destPath;
  }

  return null;
}

function main() {
  const stampPath = process.argv[2];
  const source = findSource();

  if (!source) {
    console.error(
      "No server list found. Expected the repository snapshot at\n" +
        `  ${destPath}\n` +
        "or set PSIPHON_SERVER_LIST to a local file path.",
    );
    process.exit(1);
  }

  fs.mkdirSync(path.dirname(destPath), { recursive: true });
  fs.copyFileSync(source, destPath);

  const stat = fs.statSync(destPath);
  console.log(
    `Bundled server list: ${path.relative(rootDir, destPath)} (${stat.size} bytes, from ${source})`,
  );

  if (stampPath) {
    fs.writeFileSync(stampPath, `${source}\n${stat.size}\n`);
  }
}

main();
