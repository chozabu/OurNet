use super::*;
use collaboration::{Pull, PULL, EVENT};

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct CopyJob {
    pub source: String, pub target: String,
    pub after: (u64, String), pub through: (u64, String),
    pub pull: String, pub expected: String, pub head: String, pub target_ref: String,
    pub checking: bool, pub pending: String, pub copied: u64,
    #[serde(default)] pub paused:bool,
    #[serde(default)] pub target_tip:String,
    #[serde(default)] pub target_created:u64,
    #[serde(default)] pub source_created:u64,
}

impl Git {
    fn same_audience(source:&Repo,target:&Repo)->bool {
        source.place==target.place&&(source.place==Where::Public||source.space==target.space)
    }
    fn audience(repo: &Repo) -> Audience {
        match repo.place { Where::Personal => Audience::Personal, Where::Group => Audience::Group, Where::Public => Audience::Public }
    }
    fn collaboration_space(&self, repo: &Repo) -> String {
        if repo.place == Where::Public { home(&self.me) } else { repo.space.clone() }
    }
    fn valid_collaborator(repo: &Repo, space: &str, author: &str) -> bool {
        if repo.place == Where::Public { space == home(author) } else { space == repo.space }
    }
    pub fn take_collaboration(&mut self, o: &Object) -> Option<String> {
        if where_of(&o.space)==Where::Personal&&o.author!=self.me{return None;}
        if o.kind == PULL {
            let pull = Pull::from_object(o)?;
            if Pull::load(&pull.id).is_some() { return None; }
            let Some(repo) = self.repos.get(&pull.repo) else {
                let _=collaboration::append(&format!("deferred-pulls/{}",pull.repo),&o.id,json!(o.id));
                return None;
            };
            if repo.deleted || pull.target_created!=repo.created {
                let _=collaboration::append(&format!("deferred-pulls/{}",pull.repo),&o.id,json!(o.id));return None;
            }
            if !Self::valid_collaborator(repo,&o.space,&o.author){return None;}
            let Some(source)=self.repos.get(&pull.source) else {
                let _=collaboration::append(&format!("deferred-pulls/{}",pull.source),&o.id,json!(o.id));return None;
            };
            if source.deleted||source.created!=pull.source_created{
                let _=collaboration::append(&format!("deferred-pulls/{}",pull.source),&o.id,json!(o.id));return None;
            }
            if !Self::same_audience(source,repo){return None;}
            if let Err(e) = collaboration::create(pull.clone()) { ournet_plugin::warn(&e); return None; }
            // Events can arrive before their root. Revisit only this thread once.
            let mut cursor = String::new();
            loop {
                let (events, next) = collaboration::page(&format!("pull-events/{}", pull.id), &cursor, 30);
                let mut state = Pull::load(&pull.id)?;
                for e in events {
                    let author = e["author"].as_str().unwrap_or("");
                    if Self::valid_collaborator(repo, e["space"].as_str().unwrap_or(""), author) {
                        state.apply(&e, Self::may_write(&repo.space, author));
                    }
                }
                let _ = collaboration::put("pulls", &pull.id, &ournet_plugin::serde_json::to_value(state).ok()?);
                if next.is_empty() { break; } cursor = next;
            }
            Some(pull.repo)
        } else if o.kind == EVENT {
            let id = o.json()["pull"].as_str()?.to_string();
            if let Some(pull) = Pull::load(&id) {
                let repo = self.repos.get(&pull.repo)?;
                let action=o.json()["action"].as_str().unwrap_or("").to_string();
                if !["comment","approve","request-changes","close","reopen","update","merged"].contains(&action.as_str()) { return None; }
                let maintainer=Self::may_write(&repo.space,&o.author);
                if (action=="merged"&&!maintainer) || (matches!(action.as_str(),"close"|"reopen")&&o.author!=pull.author&&!maintainer)
                    || (action=="update"&&o.author!=pull.author) { return None; }
                if !Self::valid_collaborator(repo, &o.space, &o.author) { return None; }
                collaboration::event(o, Self::may_write(&repo.space, &o.author)).ok().flatten()
            } else { let _ = collaboration::event(o, false); None }
        } else { None }
    }

    pub fn fork(&mut self) -> Result<(), String> {
        if self.copy_job.is_some() { return Err("Another repository copy is running".into()); }
        let source = self.repo.clone().ok_or("No repository")?;
        let parent = self.repos.get(&source).cloned().ok_or("No repository")?;
        let name = self.fork_name.trim().to_string();
        if !valid_name(&name) { return Err("Choose a valid fork name".into()); }
        let space = self.collaboration_space(&parent);
        let target = repo_key(&space, &name);
        if self.repos.get(&target).is_some_and(|r| !r.deleted) { return Err("That repository already exists".into()); }
        let id = ournet_plugin::publish(REPO, &space, Self::audience(&parent), &json!({
            "name": name, "description": parent.description, "parent": source, "parentCreated":parent.created,
        }))?;
        if let Some(o) = ournet_plugin::get(&id) { self.take(&o); }
        let through = self.load_pushes(&source).last().map(|p| (p.created,p.id.clone())).unwrap_or_default();
        let target_created=self.repos.get(&target).ok_or("Fork metadata has not arrived")?.created;
        self.copy_job = Some(CopyJob { source, target, through, target_created, source_created:parent.created, ..Default::default() });
        self.save_job()?;
        self.tab = Tab::Code;
        ournet_plugin::timer::set(COPY_TIMER, 1);
        Ok(())
    }
    fn save_job(&self) -> Result<(), String> {
        collaboration::put("operations", "copy", &ournet_plugin::serde_json::to_value(&self.copy_job).map_err(|e| e.to_string())?)
    }
    pub fn pending(&self, job: &mut CopyJob, sha: &str) -> Result<(), String> {
        let bucket = format!("ancestry/{}", job.pull);
        if index::get(&bucket, sha)?.is_none() {
            index::put(&bucket, &[(sha.into(), job.pending.as_bytes().to_vec())])?;
            job.pending = sha.into();
        }
        Ok(())
    }
    pub fn copy_step(&mut self) {
        let Some(mut job) = self.copy_job.take() else { return };
        if job.paused {self.copy_job=Some(job);return;}
        let outcome = (|| -> Result<bool,String> {
            if self.repos.get(&job.target).is_none_or(|r|r.deleted||r.created!=job.target_created){return Err("Target repository was deleted or recreated; the copy has stopped".into());}
            let source=self.repos.get(&job.source).ok_or("Source repository is not available")?;
            if source.deleted||source.created!=job.source_created||!Self::same_audience(source,&self.repos[&job.target]){
                return Err("Source changed or has a different sharing audience; no further packs will be imported".into());
            }
            if !job.checking {
                let tip=self.load_pushes(&job.target).last().map(|p|p.id.clone()).unwrap_or_default();
                if tip!=job.target_tip {
                    let next=self.load_pushes(&job.source).iter().find(|p|(p.created,p.id.clone())>job.after&&(p.created,p.id.clone())<=job.through).map(|p|p.id.clone());
                    let original=ournet_plugin::get(&tip);
                    let recovered_copy=original.as_ref().is_some_and(|o|o.author==self.me&&o.json()["copiedFrom"].as_str()==next.as_deref()&&next.is_some());
                    let recovered_merge=!job.pull.is_empty()&&next.is_none()&&original.as_ref().is_some_and(|o|
                        o.author==self.me&&o.json()["refs"][&job.target_ref]==job.head&&o.json()["old"][&job.target_ref]==job.expected);
                    if recovered_copy||recovered_merge {job.target_tip=tip;}
                    else{return Err("Target repository changed during the copy. Imported history is kept; review the target before retrying.".into());}
                }
            }
            if job.checking {
                let deadline = ournet_plugin::now() + STEP_MS;
                while !job.pending.is_empty() && ournet_plugin::now() < deadline {
                    let sha = job.pending.clone();
                    job.pending = String::from_utf8(index::get(&format!("ancestry/{}", job.pull), &sha)?.ok_or("Missing ancestry checkpoint")?).map_err(|e|e.to_string())?;
                    if sha == job.expected { job.checking=false; break; }
                    let commit = self.open_objects(&job.source).commit(&pack::unhex(&sha).ok_or("Bad commit")?).ok_or("Source history is not available here yet; retry after it arrives")?;
                    for parent in commit.parents { self.pending(&mut job, &pack::hex(&parent))?; }
                }
                if job.checking && job.pending.is_empty() { return Err("Branches have diverged. Merge locally with Git, push the merge commit, then update this pull request.".into()); }
                return Ok(false);
            }
            let next = if job.source==job.target { None } else { self.load_pushes(&job.source).iter()
                .find(|p| (p.created,p.id.clone()) > job.after && (p.created,p.id.clone()) <= job.through).cloned() };
            if let Some(push) = next {
                if index::get(&format!("copied/{}",job.target),&push.id)?.is_some() {
                    job.after=(push.created,push.id); return Ok(false);
                }
                let original = ournet_plugin::get(&push.id).ok_or("Source push is not available")?;
                let mut payload = original.json();
                let target = self.repos.get(&job.target).ok_or("Target repository is not available")?;
                if target.deleted { return Err("Target repository was deleted".into()); }
                payload["repo"] = target.name.clone().into();
                payload["copiedFrom"]=push.id.clone().into();
                // A PR imports objects without moving target branches first.
                if !job.pull.is_empty() { payload["refs"]=json!({}); payload["old"]=json!({}); payload.as_object_mut().unwrap().remove("head"); }
                let id = ournet_plugin::publish(PUSH, &target.space, Self::audience(target), &payload)?;
                if let Some(o)=ournet_plugin::get(&id) { self.take(&o); }
                job.target_tip=id;
                job.after=(push.created,push.id); job.copied+=1;
                Ok(false)
            } else {
                if !job.pull.is_empty() {
                    let pull = Pull::load(&job.pull).ok_or("Pull request no longer exists")?;
                    if pull.head != job.head || pull.status != "open" { return Err("Pull request changed during merge; review it again".into()); }
                    let current = self.refs(&job.target).get(&job.target_ref).cloned().unwrap_or_default();
                    if current != job.expected && current != job.head { return Err("Target branch changed during merge; refresh and retry".into()); }
                    if current != job.head {
                        let id=self.receive(&job.target, &json!({"refs":{job.target_ref.clone():job.head}, "old":{job.target_ref.clone():job.expected}}), &[])?;
                        if let Some(o)=ournet_plugin::get(&id){self.take(&o);}
                    }
                    let repo = self.repos[&job.target].clone();
                    let id=ournet_plugin::publish(EVENT,&self.collaboration_space(&repo),Self::audience(&repo),&json!({"pull":job.pull,"action":"merged","head":job.head}))?;
                    if let Some(o)=ournet_plugin::get(&id) { self.take_collaboration(&o); }
                }
                self.open_repo(&job.target);
                Ok(true)
            }
        })();
        match outcome {
            Ok(false) => { self.copy_job=Some(job); let _=self.save_job(); ournet_plugin::timer::set(COPY_TIMER, 10); }
            Ok(true) => { let _=index::clear(&format!("ancestry/{}",job.pull)); let _=self.save_job(); }
            Err(e) => { self.error=e; let _=self.save_job(); }
        }
        self.schedule(); self.show();
    }

    pub fn new_pull(&mut self) -> Result<(),String> {
        let target=self.resolve(&self.pull_target.clone())?;
        let source=self.repo.clone().ok_or("No source repository")?;
        let repo=self.repos.get(&target).cloned().ok_or("No target repository")?;
        let src=self.repos.get(&source).ok_or("No source repository")?;
        if !Self::same_audience(src,&repo) { return Err("Pull requests must stay within the same sharing audience".into()); }
        let source_created=src.created;
        let base_ref=self.pull_base_ref.clone(); let head_ref=self.branch.clone().ok_or("Choose a source branch")?;
        let base=self.refs(&target).get(&base_ref).cloned().ok_or("Target branch not found")?;
        let head=self.refs(&source).get(&head_ref).cloned().ok_or("Source branch not found")?;
        if base==head{return Err("The selected branches point to the same commit; there are no proposed changes".into());}
        if self.pull_title.trim().is_empty() { return Err("Give the pull request a title".into()); }
        let id=ournet_plugin::publish(PULL,&self.collaboration_space(&repo),Self::audience(&repo),&json!({
            "repo":target,"source":source,"title":self.pull_title.trim(),"body":self.pull_body,
            "baseRef":base_ref,"headRef":head_ref,"base":base,"head":head,"targetCreated":repo.created,"sourceCreated":source_created,
        }))?;
        if let Some(o)=ournet_plugin::get(&id) { self.take_collaboration(&o); }
        self.repo=Some(target); self.pull_selected=id; self.tab=Tab::Pulls; self.mode=Mode::Repo;
        self.pull_title.clear(); self.pull_body.clear(); self.comment_draft.clear();
        Ok(())
    }
    pub fn pull_action(&mut self, action: &str, reviewed_head:&str) -> Result<(),String> {
        let pull=Pull::load(&self.pull_selected).ok_or("Choose a pull request")?;
        let repo=self.repos.get(&pull.repo).cloned().ok_or("Target repository is not available")?;
        if repo.deleted||repo.created!=pull.target_created{return Err("This request belongs to an earlier repository".into());}
        if pull.status=="merged"&&matches!(action,"close"|"reopen"|"update") {return Err("Merged requests cannot be reopened or changed".into());}
        if !Self::valid_collaborator(&repo,&self.collaboration_space(&repo),&self.me) { return Err("Outside the sharing audience".into()); }
        if matches!(action,"approve"|"request-changes")&&reviewed_head!=pull.head{return Err("The proposed head changed; review the current commit before submitting this review".into());}
        let mut payload=json!({"pull":pull.id,"action":action,"body":self.comment_draft.trim(),"head":pull.head});
        if matches!(action,"close"|"reopen"|"update") && pull.author!=self.me && !Self::may_write(&repo.space,&self.me) { return Err("Only the author or a maintainer may change this request".into()); }
        if action=="update" {
            if pull.author!=self.me { return Err("Only the author may update the proposed head".into()); }
            payload["head"]=self.refs(&pull.source).get(&pull.head_ref).cloned().ok_or("Source branch not available")?.into();
        }
        if action=="comment" && self.comment_draft.trim().is_empty() { return Err("Write a comment first".into()); }
        if !["comment","approve","request-changes","close","reopen","update"].contains(&action) { return Err("Unknown review action".into()); }
        let id=ournet_plugin::publish(EVENT,&self.collaboration_space(&repo),Self::audience(&repo),&payload)?;
        if let Some(o)=ournet_plugin::get(&id) { self.take_collaboration(&o); }
        self.comment_draft.clear(); Ok(())
    }
    pub fn merge_pull(&mut self, reviewed_head:&str, reviewed_base:&str) -> Result<(),String> {
        if self.copy_job.is_some() { return Err("Another repository copy is running".into()); }
        let pull=Pull::load(&self.pull_selected).ok_or("Choose a pull request")?;
        let repo=self.repos.get(&pull.repo).ok_or("Target repository missing")?;
        if repo.deleted||repo.created!=pull.target_created{return Err("This request belongs to an earlier repository".into());}
        let target_created=repo.created;
        let source=self.repos.get(&pull.source).ok_or("Source repository missing")?;
        if source.deleted||source.created!=pull.source_created||!Self::same_audience(source,repo){return Err("The source and target must have the same sharing audience".into());}
        let source_created=source.created;
        if !Self::may_write(&repo.space,&self.me) || pull.status!="open" { return Err("Only a maintainer can merge an open request".into()); }
        let expected=self.refs(&pull.repo).get(&pull.base_ref).cloned().ok_or("Target branch missing")?;
        if pull.head!=reviewed_head||expected!=reviewed_base{return Err("The proposal or target changed; refresh and review before merging".into());}
        let through=self.load_pushes(&pull.source).last().map(|p|(p.created,p.id.clone())).unwrap_or_default();
        let target_tip=self.load_pushes(&pull.repo).last().map(|p|p.id.clone()).unwrap_or_default();
        let mut job=CopyJob{source:pull.source,target:pull.repo,pull:pull.id,head:pull.head,target_tip,target_created,source_created,
            expected,target_ref:pull.base_ref,through,checking:true,..Default::default()};
        let head=job.head.clone(); self.pending(&mut job,&head)?;
        self.copy_job=Some(job); self.save_job()?; ournet_plugin::timer::set(COPY_TIMER,1); Ok(())
    }

    pub fn show_pulls(&mut self, data:&mut Value, key:&str) {
        data["pullTarget"]=self.pull_target.clone().into(); data["pullBaseRef"]=self.pull_base_ref.clone().into();
        data["pullTitle"]=self.pull_title.clone().into(); data["pullBody"]=self.pull_body.clone().into();
        data["commentDraft"]=self.comment_draft.clone().into();
        let (ids,next)=collaboration::page(&format!("pull-list/{key}"),&self.pull_cursor,30);
        data["pulls"]=ids.iter().filter_map(|v|Pull::load(v.as_str()?)).filter(|p|self.repos.get(key).is_some_and(|r|p.target_created==r.created)).map(|p|json!({
            "id":p.id,"title":p.title,"author":p.author,"status":p.status,"at":p.created,
        })).collect::<Vec<_>>().into();
        data["pullsEmpty"]=data["pulls"].as_array().is_some_and(|p|p.is_empty()).into();
        self.pull_next=next; data["morePulls"]=(!self.pull_next.is_empty()).into();
        data["pullSelected"]=false.into();
        if let Some(p)=Pull::load(&self.pull_selected).filter(|p|p.repo==key&&self.repos.get(key).is_some_and(|r|r.created==p.target_created)) {
            let writable=self.repos.get(key).is_some_and(|r|Self::may_write(&r.space,&self.me));
            let (comments,next)=collaboration::page(&format!("pull-events/{}",p.id),&self.comment_cursor,30);
            data["comments"]=comments.into(); self.comment_next=next;
            data["moreComments"]=(!self.comment_next.is_empty()).into();
            data["pullSelected"]=true.into(); data["pullCanManage"]=((writable||p.author==self.me)&&p.status!="merged").into();
            data["pullCanMerge"]=(writable&&p.status=="open").into();
            let current_base=self.ref_state_cached(key).refs.get(&p.base_ref).cloned().unwrap_or_default();
            let source_name=self.repos.get(&p.source).map(|r|r.name.clone()).unwrap_or_else(|| "Source repository unavailable".into());
            let head_label=p.head_ref.strip_prefix("refs/heads/").unwrap_or(&p.head_ref);
            let base_label=p.base_ref.strip_prefix("refs/heads/").unwrap_or(&p.base_ref);
            data["pull"]=json!({"sourceName":source_name,"headLabel":head_label,"baseLabel":base_label,"currentBase":current_base,"id":p.id,"title":p.title,"body":p.body,"author":p.author,
                "status":p.status,"base":p.base,"head":p.head,"baseRef":p.base_ref,"headRef":p.head_ref,
                "source":self.repos.get(&p.source).map(|r|format!("{} / {}",r.owner,r.name)).unwrap_or(p.source),});
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn public_and_private_collaboration_do_not_cross_audiences() {
        let public=Repo{space:home("owner"),place:Where::Public,..Default::default()};
        assert!(Git::valid_collaborator(&public,&home("contributor"),"contributor"));
        assert!(!Git::valid_collaborator(&public,&home("owner"),"contributor"));
        assert!(!Git::may_write(&public.space,"contributor"));
        assert!(Git::may_write(&public.space,"owner"));
        let private=Repo{space:"group-secret".into(),place:Where::Group,..Default::default()};
        assert!(Git::valid_collaborator(&private,"group-secret","member"));
        assert!(!Git::valid_collaborator(&private,&home("member"),"member"));
        assert!(!Git::valid_collaborator(&private,"another-group","member"));
        assert!(!Git::same_audience(&private,&public));
        assert!(!Git::same_audience(&public,&private));
        let other_group=Repo{space:"other-group".into(),place:Where::Group,..Default::default()};
        assert!(!Git::same_audience(&private,&other_group));
    }
}
