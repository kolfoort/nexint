import {PDFDocument} from './assets/vendor/pdf-lib.esm.min.js';

export const UPLOADED_CONTRACT_TEMPLATE='NEX-UPLOADED-CONTRACT-20261105-R1';
export function agreementKind(version){return version?.snapshot?.document?.kind==='JVA'?'JVA':'MCNDA'}
export function validateDocumentMetadata(meta){
 if(!meta||!['MCNDA','JVA'].includes(meta.kind))throw Error('Choose MCNDA or JVA.');
 if(!/^[A-Z0-9][A-Z0-9._/-]{2,119}$/.test(meta.reference||''))throw Error('Enter the exact agreement reference (letters, numbers, dots, slashes and hyphens).');
 if(!/^[0-9a-f]{64}$/.test(meta.sha256||''))throw Error('The PDF must have a valid SHA-256 fingerprint.');
 if(!meta.filename||meta.filename.length>180||/[\r\n/\\]/.test(meta.filename)||!meta.filename.toLowerCase().endsWith('.pdf'))throw Error('Choose a PDF with a valid filename.');
 if(!Number.isInteger(meta.pages)||meta.pages<1||meta.pages>250)throw Error('The agreement must contain 1–250 pages.');
 return meta;
}
export async function readContractFile(file,kind,reference){
 if(!file||file.size<500||file.size>14_000_000)throw Error('Choose a complete PDF, maximum 14 MB.');
 const bytes=new Uint8Array(await file.arrayBuffer());
 if(new TextDecoder().decode(bytes.slice(0,5))!=='%PDF-')throw Error('This file is not a PDF.');
 const pdf=await PDFDocument.load(bytes); // Reject malformed or encrypted documents; preserve original bytes.
 if(pdf.getPageCount()<1||pdf.getPageCount()>250)throw Error('The agreement must contain 1–250 pages.');
 const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),n=>n.toString(16).padStart(2,'0')).join('');
 const metadata=validateDocumentMetadata({kind,reference:reference.trim(),filename:file.name,sha256:hash,pages:pdf.getPageCount()});
 return {bytes,metadata};
}
