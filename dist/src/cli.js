// @ts-nocheck
import { loadConfig, initConfig, defaultConfig } from './config.js';
import { PKSService } from './core/service.js';
import { registrationInput } from './forge/contract.js';
const args = process.argv.slice(2);
const cmd = args[0] || 'status';
const cfgArg = args.find(x => x.startsWith('--pks-config='))?.split('=')[1];
if (cmd === 'forge-registration') {
    const cfg = await loadConfig(cfgArg);
    console.log(JSON.stringify(registrationInput(cfg.forge?.socketPath || `${cfg.dataDir}/forge.sock`), null, 2));
    process.exit(0);
}
if (cmd === 'init') {
    const path = cfgArg || 'pks.config.json';
    console.log(JSON.stringify(await initConfig(path, defaultConfig()), null, 2));
    process.exit(0);
}
const svc = await new PKSService(await loadConfig(cfgArg)).open();
try {
    if (cmd === 'sync')
        console.log(JSON.stringify(await svc.sync(), null, 2));
    else if (cmd === 'search')
        console.log(JSON.stringify(await svc.search(args.slice(1).filter(x => !x.startsWith('--')).join(' ')), null, 2));
    else if (cmd === 'read')
        console.log(JSON.stringify(await svc.read(args[1]), null, 2));
    else if (cmd === 'memory')
        console.log(JSON.stringify(svc.memory.get(args[1] || 'general'), null, 2));
    else if (cmd === 'write') {
        const content = args.slice(1).filter(x => !x.startsWith('--')).join(' ');
        console.log(JSON.stringify(await svc.writer.create({ content, title: args.find(x => x.startsWith('--title='))?.split('=')[1], domain: args.find(x => x.startsWith('--domain='))?.split('=')[1] }), null, 2));
    }
    else
        console.log(JSON.stringify(svc.status(), null, 2));
}
finally {
    svc.db.close();
}
