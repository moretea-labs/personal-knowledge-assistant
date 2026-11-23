async function body(req) {
    const buffers = [];
    for await (const chunk of req)
        buffers.push(Buffer.from(chunk));
    const text = Buffer.concat(buffers).toString('utf8');
    return text ? JSON.parse(text) : {};
}
function json(res, status, data) {
    const serialized = JSON.stringify(data, null, 2);
    res.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'content-length': Buffer.byteLength(serialized)
    });
    res.end(serialized);
}
/** Local JSON API for first-party clients such as Leafspan; no browser UI. */
export function makeHandler(service) {
    return async (req, res) => {
        try {
            const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
            const { pathname, searchParams } = url;
            if (pathname === '/api/status' && req.method === 'GET')
                return json(res, 200, service.status());
            if (pathname === '/api/sources' && req.method === 'GET')
                return json(res, 200, service.sources());
            if (pathname === '/api/entities' && req.method === 'GET') {
                return json(res, 200, service.entities(searchParams.get('q') || '', Number(searchParams.get('limit') || 50)));
            }
            if (pathname === '/api/recent-changes' && req.method === 'GET') {
                return json(res, 200, service.recentChanges(Number(searchParams.get('limit') || 50)));
            }
            if (pathname === '/api/sync' && req.method === 'POST')
                return json(res, 200, await service.sync());
            if (pathname === '/api/search' && req.method === 'GET') {
                return json(res, 200, await service.search(searchParams.get('q') || '', {
                    mode: searchParams.get('mode') || 'auto',
                    limit: Number(searchParams.get('limit') || 12),
                    documentType: searchParams.get('documentType') || undefined,
                    source: searchParams.get('source') || undefined,
                    excludeUri: searchParams.get('excludeUri') || undefined
                }));
            }
            if (pathname.startsWith('/api/read/') && req.method === 'GET') {
                return json(res, 200, await service.read(decodeURIComponent(pathname.slice('/api/read/'.length)), Number(searchParams.get('maxChars') || 20000)));
            }
            if (pathname === '/api/write' && req.method === 'POST') {
                return json(res, 200, await service.writer.create(await body(req)));
            }
            if (pathname === '/api/update' && req.method === 'POST') {
                return json(res, 200, await service.writer.update(await body(req)));
            }
            if (pathname === '/api/undo' && req.method === 'POST') {
                const request = await body(req);
                return json(res, 200, await service.writer.undo(request.mutationId));
            }
            if (pathname.startsWith('/api/memory/') && req.method === 'GET') {
                return json(res, 200, service.memory.get(decodeURIComponent(pathname.slice('/api/memory/'.length))));
            }
            if (pathname === '/api/health/timeline' && req.method === 'GET') {
                const type = searchParams.get('type') || 'creatinine';
                const rows = service.db.db.prepare(`
          SELECT m.observation_type,m.value,m.unit,m.observed_at,m.confidence,m.verified,
                 d.id document_id,d.title,d.uri
          FROM medical_observations m
          JOIN documents d ON d.id=m.source_document_id
          WHERE m.observation_type=? AND d.deleted_at IS NULL
          ORDER BY m.observed_at
        `).all(type);
                return json(res, 200, rows);
            }
            if (pathname === '/api/correct-observation' && req.method === 'POST') {
                return json(res, 200, await service.correctObservation(await body(req)));
            }
            if (pathname === '/api/organization-plan' && req.method === 'GET') {
                return json(res, 200, service.organizationPlan());
            }
            if (pathname === '/api/analyze' && req.method === 'POST') {
                const request = await body(req);
                return json(res, 200, await service.analyze(request.question || '', request.domain || 'general'));
            }
            if (pathname === '/api/review' && req.method === 'GET') {
                const low = service.db.db.prepare(`
          SELECT m.*,d.title,d.uri
          FROM medical_observations m
          JOIN documents d ON d.id=m.source_document_id
          WHERE m.confidence<0.95 AND m.verified=0
          ORDER BY m.created_at DESC
          LIMIT 100
        `).all();
                return json(res, 200, { lowConfidenceHealth: low });
            }
            return json(res, 404, { error: 'not_found' });
        }
        catch (error) {
            return json(res, 500, { error: String(error?.message || error) });
        }
    };
}
