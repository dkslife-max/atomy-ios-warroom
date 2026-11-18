(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.AtomyInsights=factory();})(typeof window!=='undefined'?window:globalThis,function(){
  'use strict';
  function date(value){const m=String(value||'').match(/^(\d{4})[-/]?(\d{2})[-/]?(\d{2})(?:[T\s].*)?$/);if(!m)return '';const d=new Date(Date.UTC(+m[1],+m[2]-1,+m[3]));return d.getUTCFullYear()===+m[1]&&d.getUTCMonth()+1===+m[2]&&d.getUTCDate()===+m[3]?`${m[1]}-${m[2]}-${m[3]}`:''}
  function day(value){const d=new Date(value);if(!Number.isFinite(d.getTime()))return '';const p=new Intl.DateTimeFormat('en-US',{timeZone:'Asia/Taipei',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(d),get=t=>p.find(x=>x.type===t).value;return `${get('year')}-${get('month')}-${get('day')}`}
  function add(value,n){const d=new Date(value+'T00:00:00Z');d.setUTCDate(d.getUTCDate()+n);return d.toISOString().slice(0,10)}
  function key(value){return value.slice(0,7)+(Number(value.slice(8,10))<=15?'-P1':'-P2')}
  function bounds(k){const m=String(k).match(/^(\d{4})-(\d{2})-P([12])$/);if(!m)return null;const start=`${m[1]}-${m[2]}-${m[3]==='1'?'01':'16'}`,end=m[3]==='1'?`${m[1]}-${m[2]}-15`:new Date(Date.UTC(+m[1],+m[2],0)).toISOString().slice(0,10);return {start,end}}
  function prev(k){return key(add(bounds(k).start,-1))}
  function create(dataset,statuses={}){
    const org=dataset.organization||{},members=new Map((org.members||[]).map(m=>[String(m.member),m])),children=new Map(),scopes=new Map(),periods=new Map();
    const root=String(org.rootId||''),asOf=day(dataset.exportedAt),quick=dataset.updateMode==='quick';
    for(const e of org.edges||[]){const p=String(e.parent);if(!children.has(p))children.set(p,[]);children.get(p).push({id:String(e.child),side:e.sideCode})}
    for(const [k,rows] of Object.entries(dataset.salesHistory||{})){
      const range=bounds(k),buyers=new Map();let invalid=0;
      for(const row of rows||[]){const d=date(row.date),id=String(row.member||''),pv=Number(row.pv);if(!range||!d||d<range.start||d>range.end||!id||!Number.isFinite(pv)){invalid++;continue}
        if(!buyers.has(id))buyers.set(id,{member:id,name:String(row.name||members.get(id)?.name||id),pv:0,rows:[],sides:new Set()});
        const item=buyers.get(id);item.pv+=pv;item.rows.push({date:d,pv});item.sides.add(row.sourceSide==='左'?'L':row.sourceSide==='右'?'R':'U');
      }
      periods.set(k,{buyers,invalid});
    }
    function scope(id){id=String(id);if(scopes.has(id))return scopes.get(id);const result={L:new Set(),R:new Set(),U:new Set(),all:new Set()};
      for(const child of children.get(id)||[]){const side=child.side==='L'||child.side==='R'?child.side:'U',todo=[child.id];while(todo.length){const member=todo.pop();if(member===id||result[side].has(member))continue;result[side].add(member);result.all.add(member);for(const next of children.get(member)||[])todo.push(next.id)}}scopes.set(id,result);return result;
    }
    function covered(from,to){if(!date(from)||!date(to)||from>to)return false;let cursor=from;
      while(cursor<=to){const k=key(cursor),end=bounds(k).end<to?bounds(k).end:to,status=statuses[k],index=periods.get(k);if(!status||!index||index.invalid)return false;
        if(status.lastAttempt&&!status.lastAttempt.complete){const failed=status.lastAttempt.period;if(!failed?.start||!failed?.end||failed.start<=end&&failed.end>=cursor)return false}
        let ranges=Array.isArray(status.coverage)?status.coverage:[];
        if(!Array.isArray(status.coverage)&&status.complete&&status.scope!=='incremental'){const captured=day(status.capturedAt);if(captured)ranges=[{start:bounds(k).start,end:bounds(k).end<add(captured,1)?bounds(k).end:add(captured,1)}]}
        let through=cursor;
        for(const range of [...ranges].sort((a,b)=>String(a.start).localeCompare(String(b.start)))){if(!date(range.start)||!date(range.end)||range.start>through)continue;if(range.end>=through)through=add(range.end,1)}
        if(through<=end)return false;cursor=add(end,1);
      }return true;
    }
    function contribution(id,k){id=String(id);const tree=scope(id),data=periods.get(k),active={L:0,R:0,U:0},contributors=[];let negativePv=0,unmapped=0;
      for(const item of data?.buyers.values()||[]){if(item.member===id)continue;let side;
        if(id===root){side=item.sides.size===1?[...item.sides][0]:'U';if(!members.has(item.member)&&item.pv>0)unmapped++}
        else {if(!tree.all.has(item.member))continue;side=tree.L.has(item.member)?'L':tree.R.has(item.member)?'R':'U'}
        if(item.pv>0){active[side]++;contributors.push({...item,side})}else if(item.pv<0)negativePv+=item.pv;
      }
      contributors.sort((a,b)=>b.pv-a.pv||a.member.localeCompare(b.member));const positivePv=contributors.reduce((n,x)=>n+x.pv,0),share=n=>positivePv?contributors.slice(0,n).reduce((s,x)=>s+x.pv,0)/positivePv*100:null;
      return {active,contributors,positivePv,negativePv,top1:share(1),top3:share(3),unmapped,invalid:data?.invalid||0,hasData:!!data};
    }
    function positiveAfter(id,k,from){const item=periods.get(k)?.buyers.get(String(id));return !!item&&item.rows.filter(row=>row.date>=from).reduce((sum,row)=>sum+row.pv,0)>0}
    function cohort(id,k,today){const range=bounds(k);if(!range)return {members:[],unknownDates:0};const tree=scope(id),end=range.end<add(today,1)?range.end:add(today,1),list=[];let unknownDates=0;
      for(const member of tree.all){const m=members.get(member),joined=date(m?.joinDate);if(!joined||(asOf&&joined>asOf)){unknownDates++;continue}if(joined<range.start||joined>range.end)continue;
        const bought=positiveAfter(member,k,joined),hasRows=periods.get(k)?.buyers.get(member)?.rows.some(row=>row.date>=joined),complete=joined<=end&&covered(joined,end);list.push({member,name:m?.name&&m.name!=='XXX'?m.name:member,joined,side:tree.L.has(member)?'L':tree.R.has(member)?'R':'U',bought,state:bought?'bought':hasRows?'adjusted':complete?'not-observed':'unknown'});
      }return {members:list.sort((a,b)=>a.joined.localeCompare(b.joined)||a.member.localeCompare(b.member)),unknownDates,quick};
    }
    function summary(id,k,today=day(new Date())){const range=bounds(k),data=contribution(id,k),newcomers=cohort(id,k,today),previous=range?cohort(id,prev(k),today):{members:[]},eligible=previous.members.filter(m=>m.bought),repeat=eligible.map(m=>({...m,repeated:positiveAfter(m.member,k,m.joined),repeatAdjusted:!!periods.get(k)?.buyers.get(m.member)?.rows.length}));
      const end=range&&(range.end<add(today,1)?range.end:add(today,1));
      return {...data,newcomers,repeat,repeatCount:repeat.filter(m=>m.repeated).length,complete:!!range&&range.start<=end&&covered(range.start,end),previousCohortComplete:!!range&&covered(bounds(prev(k)).start,bounds(prev(k)).end),quick,asOf};
    }
    function care(id,today,crm={}){id=String(id);const tree=scope(id),current=key(today),currentRange=bounds(current),last=prev(current),before=prev(last),earlier=prev(before),fresh=day(statuses[current]?.capturedAt)===today;
      const pending=new Map();
      const record=member=>crm[member]||{},belongs=(member,r)=>r.leaderMember?String(r.leaderMember)===id:r.prospect||member.startsWith('prospect:')||member===id||tree.all.has(member);
      function include(member,reason,rank){const r=record(member);if(r.archived)return;if(!pending.has(member))pending.set(member,{member,name:r.name||members.get(member)?.name||member,reasons:[],rank,due:r.nextContact||''});const item=pending.get(member);item.reasons.push(reason);item.rank=Math.min(item.rank,rank)}
      for(const [member,r]of Object.entries(crm)){if(r.archived||!belongs(member,r))continue;const due=date(r.nextContact);if(due&&due<=today)include(member,due<today?`聯繫已逾期（${due}）`:'今天約定聯繫',due<today?0:1)}
      const purchaseReady=fresh&&covered(currentRange.start,add(today,1)),historyReady=covered(bounds(earlier).start,bounds(last).end);
      if(fresh)for(const member of tree.all){const m=members.get(member),r=record(member),joined=date(m?.joinDate);if(m?.active===false||r.archived||!belongs(member,r)||r.lastContact===today||(r.logs||[]).some(x=>x.date===today)||(date(r.nextContact)&&r.nextContact>today))continue;
        if(joined&&joined>=bounds(last).start&&joined<=add(today,-3)&&covered(joined,add(today,1))){let hasRows=false;for(const k of [last,current])if(periods.get(k)?.buyers.get(member)?.rows.some(row=>row.date>=joined))hasRows=true;if(!hasRows)include(member,'入會滿 3 天，完整已讀日期尚未見首購',2)}
        if(purchaseReady&&historyReady){const net=k=>periods.get(k)?.buyers.get(member)?.pv||0;if(net(earlier)>0&&net(before)>0&&!periods.get(last)?.buyers.has(member)&&!periods.get(current)?.buyers.has(member))include(member,'先前連續 2 期有購買，上一期至今尚未見回購',3)}
      }
      return {items:[...pending.values()].sort((a,b)=>a.rank-b.rank||a.due.localeCompare(b.due)||a.member.localeCompare(b.member)),fresh,purchaseReady,historyReady,quick};
    }
    return {scope,covered,contribution,cohort,summary,care,members};
  }
  return {create,date,day,add,key,bounds,prev,today:()=>day(new Date())};
});
