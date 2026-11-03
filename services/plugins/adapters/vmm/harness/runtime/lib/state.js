/**
 * Process-wide state shared by the Aseman plugins of one dsh host: they are
 * loaded into the same process from this package, so one module instance.
 */

import { Bindings } from './bindings.js'

export const bindings = new Bindings()
