
-record(steve_state, {  reqs, % Request Definitions (To send to general clients)
                        caps, % CapStruct for Matching against
                        db,   % DB Handle 

                        %%%  Temporary State maintained: %%%
                        
                        % If local node accepts external or local request, we 
                        % save our action match here for look up. When we get 
                        % Accept, we can remove the action list from this list. 
                        cap_store = [], % {ComputationID, Capability ActionList}

                        %% If we personally send out a request, and are waiting
                        %% for responses back, the request ID is store here.
                        %% It is only removed upon cancelation or we heard about
                        %% a rescast.
                        out_req   = [], % { ComputationID, ClientID }

                        %% If we heard someone was able to compute one of our
                        %% outstanding requests we save them until they are
                        %% accepted by the client or the computation is removed
                        %% from out_req.
                        waiting_acceptors = [], % { ComputationID, FriendConn }

                        %% Minor hack for temporary persistence.
                        temp_persist = [] % { ComputationID, HasResult }
                     }).


