import { extractHealth } from './health.js';
import { extractMedia } from './media.js';
export function extractDomains(text, observedAt) { const a = extractHealth(text, observedAt), b = extractMedia(text); return { documentType: b.documentType || a.documentType, tags: [...(a.tags || []), ...(b.tags || [])], records: [...(a.records || []), ...(b.records || [])], observations: [...(a.observations || []), ...(b.observations || [])] }; }
