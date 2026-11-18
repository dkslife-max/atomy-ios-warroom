(function(root,factory){if(root&&root.document)root.AtomySalesTransport=factory();else if(typeof module==='object'&&module.exports)module.exports=factory();})(typeof window!=='undefined'?window:this,function(){
  'use strict';
  const normalized = key => String(key||'').toLowerCase().replace(/[^a-z0-9]/g,'');
  function role(key, bindings={}) {
    const k=normalized(key);
    if((bindings.start||[]).some(v=>normalized(v)===k))return 'start';
    if((bindings.end||[]).some(v=>normalized(v)===k))return 'end';
    const dated=/date|dt|ymd|day/.test(k);
    if((dated&&/start|strt|strdate|strdt|begin|bgn|from|datefr|frdate|dtfr|frdt|ymdfr|frymd/.test(k))||/^(sdate|sdt|sday|from|start|begin)$/.test(k))return 'start';
    if((dated&&/end|finish|until|todate|todt|dateto|dtto|ymdto|toymd/.test(k))||/^(edate|edt|eday|to|end|finish|lastdate|lastdt)$/.test(k))return 'end';
    return '';
  }
  function formatDate(wanted, original) {
    const value=String(original||'');
    if(/^\d{8}(?:\d{6})?$/.test(value))return wanted.replace(/-/g,'')+value.slice(8);
    if(/^\d{4}\/\d{1,2}\/\d{1,2}/.test(value))return wanted.replace(/-/g,'/')+value.slice(10);
    if(/^\d{4}\.\d{1,2}\.\d{1,2}/.test(value))return wanted.replace(/-/g,'.')+value.slice(10);
    return wanted+(value.length>10?value.slice(10):'');
  }
  function isPage(key){return /^(page|pageno|pagenum|pageindex|pagenumber|currentpage|pageidx)$/.test(normalized(key));}
  function rewriteEntries(entries, state, transport) {
    if(!state||!state.submitted)return {entries,matched:false};
    const eligible=entries.filter(([k,v])=>role(k,state.bindings)&&typeof v==='string'&&(!v||/^\d{4}[-/.]?\d{1,2}[-/.]?\d{1,2}(?:[T\s].*)?$|^\d{8}(?:\d{6})?$/.test(v)));
    if(!eligible.some(([k])=>role(k,state.bindings)==='start')||!eligible.some(([k])=>role(k,state.bindings)==='end'))return {entries,matched:false};
    const reset=!state.dateRequestSeen;
    const keys=[];
    const output=entries.map(entry=>{
      const [key,value]=entry;
      const kind=eligible.includes(entry)?role(key,state.bindings):'';
      if(kind){keys.push(key);return [key,formatDate(state[kind],value)]}
      if(reset&&isPage(key)&&/^\d+$/.test(String(value)))return [key,String(value)==='0'?'0':'1'];
      return [key,value];
    });
    state.dateRequestSeen=true;
    // Only date evidence is retained. No account, token, URL or request body is logged.
    state.dateEvidence={observed:true,start:state.start,end:state.end,keys:[...new Set(keys)],transport,resetFirstPage:reset};
    return {entries:output,matched:true};
  }
  function rewriteUrl(url,state,base) {
    const parsed=new URL(String(url),base);
    if(parsed.origin!==new URL(base).origin)return String(url);
    const result=rewriteEntries([...parsed.searchParams],state,'query-string');
    if(!result.matched)return String(url);
    parsed.search='';for(const [key,value]of result.entries)parsed.searchParams.append(key,value);
    return parsed.toString();
  }
  function resetPages(entries){return entries.map(([k,v])=>[k,isPage(k)&&/^\d+$/.test(String(v))?(String(v)==='0'?'0':'1'):v]);}
  function nestedValue(value,state,win,depth){
    return typeof value==='string'&&(/^[\s]*[\[{]/.test(value)||/(?:^|&)[^=]*(?:start|strt|from|end|date|dt)[^=]*=/i.test(value))?
      rewriteBody(value,state,win,depth+1):value;
  }
  function rewriteBody(body,state,win=globalThis,depth=0) {
    if(depth>3||!state||!state.submitted)return body;
    const reset=!state.dateRequestSeen;
    if(typeof body==='string'){
      if(/^\s*[\[{]/.test(body)){
        let object;try{object=JSON.parse(body)}catch(_){return body}
        const refs=[];
        const collect=obj=>{if(!obj||typeof obj!=='object')return;for(const [key,value]of Object.entries(obj)){if(value&&typeof value==='object')collect(value);else refs.push({obj,key,value})}};
        collect(object);let nested=false;
        for(const ref of refs){const next=nestedValue(ref.value,state,win,depth);if(next!==ref.value){nested=true;ref.value=next;ref.obj[ref.key]=next}}
        const result=rewriteEntries(refs.map(r=>[r.key,typeof r.value==='number'?String(r.value):r.value]),state,'json-body');
        if(!result.matched&&!nested)return body;
        if(reset&&state.dateRequestSeen)result.entries=resetPages(result.entries);
        result.entries.forEach(([key,value],i)=>{refs[i].obj[key]=typeof refs[i].value==='number'?Number(value):value});
        return JSON.stringify(object);
      }
      if(body.includes('=')){
        const params=new URLSearchParams(body);let nested=false;
        const entries=[...params].map(([k,v])=>{const next=nestedValue(v,state,win,depth);if(next!==v)nested=true;return[k,next]});
        const result=rewriteEntries(entries,state,'form-body');
        if(!result.matched&&!nested)return body;
        if(reset&&state.dateRequestSeen)result.entries=resetPages(result.entries);
        return new URLSearchParams(result.entries).toString();
      }
      return body;
    }
    if(win.URLSearchParams&&body instanceof win.URLSearchParams){
      const result=rewriteEntries([...body],state,'urlencoded-body');return result.matched?new win.URLSearchParams(result.entries):body;
    }
    if(win.FormData&&body instanceof win.FormData){
      const result=rewriteEntries([...body],state,'form-data');if(!result.matched)return body;
      const out=new win.FormData();for(const [k,v]of result.entries)out.append(k,v);return out;
    }
    return body;
  }
  function install(win) {
    if(win.__atomySalesTransportInstalled)return;
    win.__atomySalesTransportInstalled=true;
    const allowed=url=>{try{return new URL(String(url),win.location.href).origin===win.location.origin&&win.location.pathname==='/myoffice/mySales/lowerSales'}catch(_){return false}};
    const observe=url=>{
      const state=win.__atomyQueryState;
      if(!state||!state.submitted||!allowed(url))return null;
      state.pending++;state.requests++;state.queryRequests++;state.changedAt=Date.now();return state;
    };
    const finish=(state,failed)=>{if(state){state.pending=Math.max(0,state.pending-1);state.failed=state.failed||failed;state.changedAt=Date.now()}};
    const originalFetch=win.fetch;
    if(originalFetch)win.fetch=function(input,init){
      const originalUrl=input&&input.url||input;
      if(!allowed(originalUrl))return originalFetch.apply(this,arguments);
      const state=win.__atomyQueryState;
      const forceFirst=!!(state&&!state.dateRequestSeen);
      const bodyForSend=body=>{
        const consumed=state&&state.dateRequestSeen;
        if(state&&forceFirst)state.dateRequestSeen=false;
        const output=rewriteBody(body,state,win);
        if(state)state.dateRequestSeen=state.dateRequestSeen||consumed;
        return output;
      };
      const perform=(url,options)=>{
        const watched=observe(url&&url.url||url);
        return originalFetch.call(win,url,options).then(response=>response.clone().arrayBuffer().then(()=>{finish(watched,!response.ok);return response},()=>{finish(watched,true);return response}),error=>{finish(watched,true);throw error});
      };
      if(win.Request&&input instanceof win.Request){
        const request=new win.Request(input,init),url=rewriteUrl(request.url,state,win.location.href);
        if(!/^(GET|HEAD)$/i.test(request.method))return request.clone().text().then(body=>{
          const outgoing=bodyForSend(body);
          if(outgoing===body)return perform(url===request.url?request:new win.Request(url,request));
          return perform(new win.Request(url,{...Object.fromEntries(['method','headers','credentials','mode','cache','redirect','referrer','integrity','signal'].map(k=>[k,request[k]])),body:outgoing}));
        });
        return perform(new win.Request(url,request));
      }
      const options=init?{...init}:init;
      const url=rewriteUrl(originalUrl,state,win.location.href);
      if(options&&options.body!==undefined)options.body=bodyForSend(options.body);
      return perform(url,options);
    };
    const proto=win.XMLHttpRequest.prototype,open=proto.open,send=proto.send;
    proto.open=function(method,url){
      const args=[...arguments];this.__atomySalesUrl=String(url);
      const state=win.__atomyQueryState;
      this.__atomyFirstQuery=!!(state&&!state.dateRequestSeen);this.__atomyQueryToken=state&&state.token;
      if(allowed(url)){args[1]=rewriteUrl(url,win.__atomyQueryState,win.location.href);this.__atomySalesUrl=String(args[1])}
      return open.apply(this,args);
    };
    proto.send=function(body){
      const url=this.__atomySalesUrl,state=win.__atomyQueryState;
      const consumed=state&&state.dateRequestSeen;
      if(state&&this.__atomyFirstQuery&&this.__atomyQueryToken===state.token)state.dateRequestSeen=false;
      const outgoing=allowed(url)?rewriteBody(body,state,win):body;
      if(state)state.dateRequestSeen=state.dateRequestSeen||consumed;
      const watched=observe(url);let ended=false;
      const complete=failed=>{if(!ended){ended=true;finish(watched,failed)}};
      this.addEventListener('loadend',()=>complete(this.status<200||this.status>=400),{once:true});
      try{return send.call(this,outgoing)}catch(error){complete(true);throw error}
    };
  }
  return {role,formatDate,rewriteEntries,rewriteUrl,rewriteBody,install};
});
