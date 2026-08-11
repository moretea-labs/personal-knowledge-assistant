export function chunkDocument(doc, maxChars = 1800, overlap = 180) { const out = []; let ordinal = 0; for (const section of doc.sections) {
    const text = section.text.trim();
    if (!text)
        continue;
    for (let start = 0; start < text.length; start += Math.max(1, maxChars - overlap)) {
        const part = text.slice(start, start + maxChars).trim();
        if (!part)
            continue;
        out.push({ ordinal: ordinal++, text: part, startOffset: (section.startOffset ?? 0) + start, endOffset: (section.startOffset ?? 0) + start + part.length, page: section.page, headingPath: section.heading });
        if (start + maxChars >= text.length)
            break;
    }
} return out; }
