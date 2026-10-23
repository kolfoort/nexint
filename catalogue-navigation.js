const language=document.documentElement.lang;
const suffix=({en:'',de:'-de',es:'-es'})[language]||'';
const ranges={'#performance':'performance-fluids','#crude-oil':'crude-oils','#marine-chartering':'marine-chartering'};
if(document.body.hasAttribute('data-catalogue-home')){
 const followLegacyLink=()=>{const page=ranges[location.hash];if(page)location.replace(page+suffix+'.html'+location.search+location.hash);};
 followLegacyLink();addEventListener('hashchange',followLegacyLink);
}
const back=document.querySelector('[data-quote-return]');
if(back){const range=new URLSearchParams(location.search).get('range');if(Object.values(ranges).includes(range))back.href=range+suffix+'.html';}
