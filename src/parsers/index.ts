// @ts-nocheck
import { readFile } from 'node:fs/promises';
import { extname } from 'node:path';
import { spawnSync } from 'node:child_process';
import type { ParsedDocument } from '../types.js';

function stripXml(x:string){return x.replace(/<w:tab\/>/g,'\t').replace(/<w:br\/>/g,'\n').replace(/<\/w:p>/g,'\n').replace(/<[^>]+>/g,' ').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/\s+\n/g,'\n').replace(/[ \t]{2,}/g,' ').trim();}
function command(command:string,args:string[]) { const r=spawnSync(command,args,{encoding:'utf8',maxBuffer:32*1024*1024}); return r.status===0?String(r.stdout):''; }
function unzipEntry(path:string,entry:string){return command('unzip',['-p',path,entry]);}

export function splitSections(text:string): ParsedDocument {
  const lines=text.split(/\r?\n/); const sections=[] as any[]; let heading=''; let buf:string[]=[]; let offset=0;
  const flush=()=>{const t=buf.join('\n').trim(); if(t) sections.push({heading:heading||undefined,text:t,startOffset:offset,endOffset:offset+t.length}); offset+=t.length+1; buf=[];};
  for(const line of lines){ if(/^#{1,6}\s+/.test(line)){flush();heading=line.replace(/^#{1,6}\s+/,'').trim();}else buf.push(line);} flush();
  if(!sections.length && text.trim()) sections.push({text:text.trim(),startOffset:0,endOffset:text.trim().length});
  return {text,sections,metadata:{}};
}
export async function parseDocument(path:string):Promise<ParsedDocument>{
  const ext=extname(path).toLowerCase();
  if(['.md','.txt','.json','.csv','.tsv','.yaml','.yml','.html','.htm','.log'].includes(ext)){ let t=await readFile(path,'utf8'); if(ext==='.html'||ext==='.htm')t=t.replace(/<script[\s\S]*?<\/script>/gi,' ').replace(/<style[\s\S]*?<\/style>/gi,' ').replace(/<[^>]+>/g,' '); return splitSections(t); }
  if(ext==='.pdf'){ const t=command('pdftotext',['-layout',path,'-']); if(t) return splitSections(t); return {text:'',sections:[],metadata:{parserWarning:'pdftotext unavailable or PDF has no native text'}}; }
  if(ext==='.docx'){ const xml=unzipEntry(path,'word/document.xml'); return splitSections(stripXml(xml)); }
  if(ext==='.pptx'){ const list=command('unzip',['-Z1',path]).split(/\r?\n/).filter(x=>/^ppt\/slides\/slide\d+\.xml$/.test(x)).sort(); const pages=list.map((e,i)=>({page:i+1,text:stripXml(unzipEntry(path,e))})); return {text:pages.map(x=>x.text).join('\n\n'),sections:pages,metadata:{slideCount:pages.length}}; }
  if(ext==='.xlsx'){ const shared=stripXml(unzipEntry(path,'xl/sharedStrings.xml')); const sheets=command('unzip',['-Z1',path]).split(/\r?\n/).filter(x=>/^xl\/worksheets\/sheet\d+\.xml$/.test(x)).sort(); const texts=sheets.map((e,i)=>`Sheet ${i+1}\n${stripXml(unzipEntry(path,e))}`); return splitSections([shared,...texts].join('\n'));
  }
  return {text:'',sections:[],metadata:{unsupported:true}};
}
export const supportedExtensions = new Set(['.md','.txt','.json','.csv','.tsv','.yaml','.yml','.html','.htm','.log','.pdf','.docx','.pptx','.xlsx']);
