import { createHeartbeatEvent } from "./runtime";

process.stdout.write(`${JSON.stringify(createHeartbeatEvent("bootstrap"))}\n`);
