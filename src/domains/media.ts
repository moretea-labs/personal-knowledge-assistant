// @ts-nocheck
import type { DomainExtraction } from '../types.js';
import { parseFrontmatter } from './frontmatter.js';
export function extractMedia(text:string):DomainExtraction{
 const fm=parseFrontmatter(text); const type=(fm.type||'').toLowerCase();
 if(['movie','movie_watch','film'].includes(type)){ const title=fm.title||fm.movie; if(!title)return{}; return {documentType:'movie_record',tags:['movies'],records:[{domain:'movies',recordType:'movie_watch',entityKey:title,data:{title,rating:num(fm.rating),watched_at:fm.watched_at||fm.date,genres:list(fm.genres),favorite:bool(fm.favorite)},authority:'canonical_source',confidence:1,observedAt:fm.watched_at||fm.date}]}; }
 if(['book','book_record','reading'].includes(type)){ const title=fm.title||fm.book; if(!title)return{}; return {documentType:'book_note',tags:['books'],records:[{domain:'books',recordType:'book_record',entityKey:title,data:{title,author:fm.author,status:fm.status||'finished',rating:num(fm.rating),genres:list(fm.genres),finished_at:fm.finished_at},authority:'canonical_source',confidence:1,observedAt:fm.finished_at}]}; }
 return{};
}
const num=(x?:string)=>x?Number(x):undefined; const list=(x?:string)=>x?x.replace(/^\[|\]$/g,'').split(',').map(v=>v.trim()).filter(Boolean):[]; const bool=(x?:string)=>x?['true','yes','1'].includes(x.toLowerCase()):false;
