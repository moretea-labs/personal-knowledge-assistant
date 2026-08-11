// @ts-nocheck
const wait = (ms) => new Promise(r => setTimeout(r, ms));
export class NotionSource {
    token;
    nextRequestAt = 0;
    constructor(token) {
        this.token = token;
    }
    async req(path, init = {}) {
        for (let attempt = 0; attempt < 5; attempt++) {
            const delay = Math.max(0, this.nextRequestAt - Date.now());
            if (delay)
                await wait(delay);
            this.nextRequestAt = Date.now() + 350;
            const r = await fetch(`https://api.notion.com/v1${path}`, { ...init, headers: { Authorization: `Bearer ${this.token}`, 'Notion-Version': '2026-03-11', 'Content-Type': 'application/json', ...(init.headers || {}) } });
            if (r.status === 429) {
                const seconds = Number(r.headers.get('retry-after') || '1');
                await wait(Number.isFinite(seconds) ? Math.max(350, seconds * 1000) : 1000);
                continue;
            }
            if (!r.ok)
                throw new Error(`Notion ${r.status}: ${await r.text()}`);
            return r.json();
        }
        throw new Error('Notion 429: retry budget exhausted');
    }
    async search(query = '', startCursor) { const body = { page_size: 100 }; if (query)
        body.query = query; if (startCursor)
        body.start_cursor = startCursor; return this.req('/search', { method: 'POST', body: JSON.stringify(body) }); }
    async pageBlocks(pageId) { let cursor; const all = []; do {
        const q = cursor ? `?page_size=100&start_cursor=${encodeURIComponent(cursor)}` : '?page_size=100';
        const x = await this.req(`/blocks/${pageId}/children${q}`);
        all.push(...x.results);
        cursor = x.has_more ? x.next_cursor : undefined;
    } while (cursor); return all; }
    blocksToText(blocks) { return blocks.map(b => { const rich = b[b.type]?.rich_text || []; return rich.map((r) => r.plain_text || '').join(''); }).filter(Boolean).join('\n'); }
    async createPage(parentPageId, title, content) { const children = content.match(/[\s\S]{1,1800}/g)?.map(text => ({ object: 'block', type: 'paragraph', paragraph: { rich_text: [{ type: 'text', text: { content: text } }] } })) || []; return this.req('/pages', { method: 'POST', body: JSON.stringify({ parent: { page_id: parentPageId }, properties: { title: { type: 'title', title: [{ type: 'text', text: { content: title } }] } }, children }) }); }
    async archivePage(pageId) { return this.req(`/pages/${pageId}`, { method: 'PATCH', body: JSON.stringify({ archived: true }) }); }
}
