// JavaScript / Node FFI for type_graph/sys.gleam.

import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { spawn } from "node:child_process";
import { Ok, Error as GError } from "./gleam.mjs";

export function writeTempFile(filename, content) {
  try {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gleam-type-graph-"));
    const out = path.join(dir, filename);
    fs.writeFileSync(out, content, "utf8");
    return new Ok(out);
  } catch (err) {
    return new GError(String(err && err.message ? err.message : err));
  }
}

export function openInBrowser(file) {
  let cmd;
  let args;
  switch (process.platform) {
    case "darwin":
      cmd = "open";
      args = [file];
      break;
    case "win32":
      cmd = "cmd";
      args = ["/c", "start", "", file];
      break;
    default:
      cmd = "xdg-open";
      args = [file];
  }
  try {
    const child = spawn(cmd, args, { stdio: "ignore", detached: true });
    child.on("error", () => {});
    child.unref();
    return new Ok(undefined);
  } catch (err) {
    return new GError(String(err && err.message ? err.message : err));
  }
}
