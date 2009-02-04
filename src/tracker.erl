-module(tracker).

-export([init/0, tracker_request/7, tracker_request_stopped/2, tracker_info/1]).


-record(peer, {hash_peer,
	       ip, port,
	       downloaded, uploaded,
	       left,
	       speed, last}).

-define(RESPONSE_PEER_COUNT, 10).


init() ->
    util:safe_mnesia_create_table(peer, [{attributes, record_info(fields, peer)}]).


tracker_request(HashId, PeerId, IP, Port, Uploaded, Downloaded, Left) ->
    Now = util:mk_timestamp(),
    F = fun() ->
		%% look if exsits before lock
		case torrent:torrent_name_by_id_t(HashId) of
		    not_found -> not_found;
		    {ok, _} ->
			mnesia:write_lock_table(peer),
			Speed = case mnesia:read({peer, {HashId, PeerId}}) of
				    [#peer{downloaded = DownloadedOld,
					   last = LastOld}] ->
					(DownloadedOld - DownloadedOld) / (LastOld - Now);
				    [] ->
					0
				end,
			io:format("New speed: ~p/s~n",[Speed]),
			mnesia:write(#peer{hash_peer = {HashId, PeerId},
					   ip = IP, port = Port,
					   downloaded = Downloaded, uploaded = Uploaded,
					   left = Left,
					   speed = Speed, last = Now}),
			ok
		end
	end,

    case mnesia:transaction(F) of
	{atomic, ok} ->
	    %% Assemble result
	    AllPeers = dirty_hash_peers(HashId),
	    PeersWithoutMe =
		lists:filter(
		  fun(#peer{hash_peer = {_, PeerPeerId}}) ->
			  PeerId =/= PeerPeerId
		  end, AllPeers),
	    NeededPeers =
		case Left of
		    0 ->
			lists:filter(fun(#peer{left = PeerLeft}) ->
					     PeerLeft > 0
				     end, PeersWithoutMe);
		    _ ->
			PeersWithoutMe
		end,
	    SomePeers = pick_randomly(NeededPeers, ?RESPONSE_PEER_COUNT),

	    %% Assemble relevant info
	    {peers, [{PeerPeerId, PeerIP, PeerPort}
		     || #peer{hash_peer = {_, PeerPeerId},
			      ip = PeerIP,
			      port = PeerPort} <- SomePeers]};

	{atomic, not_found} ->
	    not_found
    end.


tracker_request_stopped(HashId, PeerId) ->
    F = fun() ->
		mnesia:delete({peer, {HashId, PeerId}})
	end,
    {atomic, _} = mnesia:transaction(F).


tracker_info(HashId) ->
    Peers = dirty_hash_peers(HashId),
    {Seeders, Leechers} =
	lists:foldl(fun(#peer{left = 0}, {S, L}) ->
			    {S + 1, L};
		       (#peer{left = PeerLeft}, {S, L}) when PeerLeft > 0 ->
			    {S, L + 1}
		    end, {0, 0}, Peers),
    {Seeders, Leechers}.


dirty_hash_peers(HashId) ->
    mnesia:dirty_select(peer, [{#peer{hash_peer = '$1',
				      _ = '_'},
				[{'==', {element, 1, '$1'}, HashId}],
				['$_']}]).


pick_randomly(_, 0) -> [];
pick_randomly([], _) -> [];
pick_randomly(List, NToPick) ->
    E = lists:nth(random:uniform(length(List)), List),
    List2 = lists:delete(E, List),
    [E | pick_randomly(List2, NToPick - 1)].