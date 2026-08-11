// @ts-nocheck
import type { DomainExtraction, MedicalObservationInput } from '../types.js';
const tests = [
  {type:'creatinine', names:['creatinine','肌酐','肌酸酐'], units:['μmol/L','umol/L','µmol/L','mg/dL']},
  {type:'cystatin_c', names:['cystatin c','cystatin-c','胱抑素c','胱抑素 C','胱抑素C'], units:['mg/L']},
  {type:'hemoglobin', names:['hemoglobin','血红蛋白','hgb'], units:['g/L','g/dL']},
  {type:'egfr', names:['eGFR','估算肾小球滤过率','肾小球滤过率'], units:['mL/min/1.73m2','ml/min']},
  {type:'tacrolimus_trough', names:['tacrolimus','他克莫司','FK506'], units:['ng/mL']}
];
function escape(s:string){return s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');}
export function extractHealth(text:string, observedAt?:string):DomainExtraction{
 const obs:MedicalObservationInput[]=[];
 for(const t of tests){ for(const name of t.names){ const re=new RegExp(`(?:${escape(name)})[^0-9]{0,28}([0-9]+(?:\\.[0-9]+)?)\\s*(${t.units.map(escape).join('|')})?`,'ig'); let m; while((m=re.exec(text))){ obs.push({observationType:t.type,value:Number(m[1]),unit:m[2],observedAt,sourceAnchor:m[0].slice(0,160),extractionMethod:'regex_native_text',confidence:0.9}); } } }
 return obs.length?{documentType:'health_report',observations:dedupe(obs),tags:['health']}:{ };
}
function dedupe(xs:MedicalObservationInput[]){ const seen=new Set<string>(); return xs.filter(x=>{const k=`${x.observationType}|${x.value}|${x.unit||''}|${x.sourceAnchor||''}`; if(seen.has(k))return false;seen.add(k);return true;}); }
