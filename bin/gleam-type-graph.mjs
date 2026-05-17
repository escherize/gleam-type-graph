#!/usr/bin/env node
// Thin wrapper that boots the Gleam-compiled JS module.

import { main } from "../build/dev/javascript/type_graph/type_graph.mjs";

main();
