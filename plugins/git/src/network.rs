use super::*;
pub const GRAPH_TIMER:u64=4;
pub struct DiskQueue {bucket:String,head:String,tail:String}
impl DiskQueue {
    fn new(key:&str)->Self {Self{bucket:format!("network-queue/{key}"),head:String::new(),tail:String::new()}}
    fn is_empty(&self)->bool {self.head.is_empty()}
    fn push(&mut self,repo:String,sha:Sha,lane:usize)->Result<(),String>{
        let key=pack::hex(&sha);
        if index::get(&self.bucket,&key)?.is_some(){return Ok(());}
        let mut entries=vec![(key.clone(),json!({"repo":repo,"lane":lane,"next":""}).to_string().into_bytes())];
        if !self.tail.is_empty(){
            let mut tail=collaboration::get(&self.bucket,&self.tail).ok_or("Graph queue checkpoint missing")?;
            tail["next"]=key.clone().into();entries.push((self.tail.clone(),tail.to_string().into_bytes()));
        }
        index::put(&self.bucket,&entries)?;
        if self.head.is_empty(){self.head=key.clone();} self.tail=key;Ok(())
    }
    fn pop_front(&mut self)->Result<Option<(String,Sha,usize)>,String>{
        if self.head.is_empty(){return Ok(None);}
        let key=self.head.clone();
        let node=collaboration::get(&self.bucket,&key).ok_or("Graph queue checkpoint missing")?;
        self.head=node["next"].as_str().unwrap_or("").into();if self.head.is_empty(){self.tail.clear();}
        Ok(Some((node["repo"].as_str().ok_or("Invalid graph repository")?.into(),
            pack::unhex(&key).ok_or("Invalid graph commit")?,node["lane"].as_u64().unwrap_or(0) as usize)))
    }
}
pub struct Graph {
    pub key:String, pub pending:DiskQueue, pub rows:Vec<Value>,
    pub lanes:Vec<Value>, pub labels:BTreeMap<Sha,Vec<String>>, pub loading:bool,
}
impl Git {
    fn root(&self,key:&str)->String {
        let mut current=key.to_string(); let mut seen=BTreeSet::new();
        while seen.insert(current.clone()) {
            let Some(parent)=self.repos.get(&current).map(|r|r.parent.as_str()).filter(|p|!p.is_empty()) else { break };
            let parent_at=self.repos[&current].parent_at;
            if let Some(parent_repo)=self.repos.get(parent){
                let child=&self.repos[&current];
                if child.place!=parent_repo.place||(child.place!=Where::Public&&child.space!=parent_repo.space){return current;}
            }

            if self.repos.get(parent).is_none_or(|r|r.created!=parent_at) {return format!("{parent}@{parent_at}");}
            current=parent.into();
        }
        current
    }
    pub fn family(&self,key:&str)->Vec<String> {
        let root=self.root(key);
        self.repos.values().filter(|r|!r.deleted&&self.root(&r.key)==root).map(|r|r.key.clone()).collect()
    }
    pub fn show_network(&mut self,data:&mut Value,key:&str) {
        if self.graph.as_ref().is_none_or(|g|g.key!=key) {
            let _=index::clear(&format!("network/{key}"));
            let _=index::clear(&format!("network-queue/{key}"));
            let family=self.family(key);
            let mut refs=Vec::new();
            for repo in &family {
                for (name,sha) in self.refs(repo) {
                    if let Some(sha)=pack::unhex(&sha).filter(|_|name.starts_with("refs/heads/")) {
                        refs.push((repo.clone(),name,sha));
                    }
                }
            }
            let mut pending=DiskQueue::new(key); let mut lanes=Vec::new(); let mut labels=BTreeMap::<Sha,Vec<String>>::new();
            data["networkMoreBranches"]=(refs.len()>self.network_offset+50).into();
            self.network_has_more=refs.len()>self.network_offset+50;
            for (lane,(repo,name,sha)) in refs.into_iter().skip(self.network_offset).take(50).enumerate() {
                let r=&self.repos[&repo];
                let label=format!("{} / {} · {}",&r.owner[..r.owner.len().min(8)],r.name,name.trim_start_matches("refs/heads/"));
                lanes.push(json!({"name":label,"repo":repo}));
                labels.entry(sha).or_default().push(label);
                if let Err(error)=pending.push(repo,sha,lane){self.error=error;}
            }
            self.graph=Some(Graph{key:key.into(),pending,rows:Vec::new(),lanes,labels,loading:true});
            ournet_plugin::timer::set(GRAPH_TIMER,1);
        }
        let graph=self.graph.as_ref().unwrap();
        data["networkNodes"]=graph.rows.clone().into(); data["networkLanes"]=graph.lanes.clone().into();
        data["networkLoading"]=graph.loading.into();
        data["networkMore"]=(!graph.pending.is_empty()).into();
        data["networkMoreBranches"]=self.network_has_more.into();
        data["networkPreviousBranches"]=(self.network_offset>0).into();
        data["networkForks"]=self.family(key).iter().filter_map(|k|self.repos.get(k)).map(|r|json!({
            "key":r.key,"name":r.name,"owner":r.owner,"parent":r.parent,
        })).collect::<Vec<_>>().into();
    }
    pub fn graph_more(&mut self) {
        if let Some(g)=self.graph.as_mut() { if !g.loading { g.rows.clear(); g.loading=true; ournet_plugin::timer::set(GRAPH_TIMER,1); } }
    }
    pub fn graph_step(&mut self) {
        let Some(mut g)=self.graph.take() else { return };
        let until=ournet_plugin::now()+STEP_MS;
        while g.rows.len()<128 && ournet_plugin::now()<until {
            let (repo,sha,lane)=match g.pending.pop_front(){Ok(Some(value))=>value,Ok(None)=>break,Err(e)=>{self.error=e;g.loading=false;break}};
            let objects=self.open_objects(&repo); let sha=objects.peel(sha);
            let c=objects.commit(&sha);
            if let Some(c)=c {
                for parent in &c.parents { if let Err(e)=g.pending.push(repo.clone(),*parent,lane){self.error=e;} }
                g.rows.push(json!({"sha":pack::hex(&sha),"repo":repo,"lane":lane,"title":c.title(),
                    "author":c.author.name,"at":c.committer.time*1000,
                    "parents":c.parents.iter().map(pack::hex).collect::<Vec<_>>(),
                    "labels":g.labels.get(&sha).cloned().unwrap_or_default(),}));
            } else { g.rows.push(json!({"sha":pack::hex(&sha),"repo":repo,"lane":lane,
                "title":"Commit not available on this device yet","author":"","at":0,"parents":[],"labels":[]})); }
        }
        g.loading=g.rows.len()<128&&!g.pending.is_empty();
        if g.loading { ournet_plugin::timer::set(GRAPH_TIMER,16); }
        self.graph=Some(g);
        if self.tab==Tab::Network { self.show(); }
    }
    pub fn compare(&mut self)->Result<(),String> {
        let key=self.repo.clone().ok_or("No repository")?;
        let source=if self.compare_source.trim().is_empty() {key.clone()} else {self.resolve(&self.compare_source.clone())?};
        if !self.family(&key).contains(&source) {return Err("Choose this repository or a fork in its network".into());}
        let resolve=|g:&mut Git,k:&str,v:&str| g.refs(k).get(v).cloned().or_else(||g.refs(k).get(&format!("refs/heads/{v}")).cloned()).or_else(||pack::unhex(v).map(|_|v.into()));
        let base=resolve(self,&key,&self.compare_base.clone()).ok_or("Base ref or commit not found")?;
        let head=resolve(self,&source,&self.compare_head.clone()).ok_or("Head ref or commit not found")?;
        self.comparison=Some((source,base,head.clone())); self.commit=Some(head); self.mode=Mode::Commit; self.diff_shown=1500;
        Ok(())
    }
}
