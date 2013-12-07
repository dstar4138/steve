
-record(steve_state, {  reqs, caps, db,
                        % Temporary State maintained:
                        cap_store = [], % ReqHash -> Capability Action store.
                        out_req   = [], % ReqHash -> Outstanding Requests.
                        waiting_acceptors = [] % ReqHash -> Friendnfo, FriendConn 
                        }).


