// @ts-nocheck
import type { DomainExtraction } from '../types.js'; import { extractHealth } from './health.js'; import { extractMedia } from './media.js';
export function extractDomains(text:string, observedAt?:string):DomainExtraction { const a=extractHealth(text,observedAt), b=extractMedia(text); return {documentType:b.documentType||a.documentType,tags:[...(a.tags||[]),...(b.tags||[])],records:[...(a.records||[]),...(b.records||[])],observations:[...(a.observations||[]),...(b.observations||[])]}; }
