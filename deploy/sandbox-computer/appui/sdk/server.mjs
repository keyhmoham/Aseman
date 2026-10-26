// ES module entry of the Aseman server SDK (see server.cjs).
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const sdk = require("./server.cjs");

export const { Aseman, AsemanError, Client } = sdk;
export default sdk.Aseman;
