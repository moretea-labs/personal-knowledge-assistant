// @ts-nocheck
import { createHash, randomUUID } from 'node:crypto';
export const id = () => randomUUID();
export const stableId = (prefix: string, value: string) => `${prefix}_${createHash('sha1').update(value).digest('hex').slice(0,24)}`;
