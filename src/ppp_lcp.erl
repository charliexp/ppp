-module(ppp_lcp).

-behaviour(ppp_fsm).
-behaviour(ppp_proto).

%% API
-export([start_link/2]).
-export([frame_in/2, lowerup/1, lowerdown/1, loweropen/1, lowerclose/2]).

%% ppp_fsm callbacks
-export([init/2, up/1, down/1, starting/1, finished/1]).
-export([resetci/1, addci/2, ackci/3, nakci/4, rejci/3, reqci/4]).
-export([handler_lower_event/3]).

-include("ppp_fsm.hrl").
-include("ppp_lcp.hrl").

-define(MINMRU, 128).
-define(MAXMRU, 1500).
-define(DEFMRU, 1500).
-define(PPP_LQR, 16#c025).
-define(CBCP_OPT, 6).
-define(CHAP_ALL_AUTH, ['MS-CHAP-v2', 'MS-CHAP', sha1, md5]).

-record(state, {
	  config			:: list(),
	  passive = false		:: boolean(),			%% Don't die if we don't get a response
	  silent = true			:: boolean(),			%% Wait for the other end to start first
	  restart = false		:: boolean(),			%% Restart vs. exit after close

	  link				:: pid(),

	  want_opts			:: #lcp_opts{},			%% Options that we want to request
	  got_opts			:: #lcp_opts{}, 		%% Options that peer ack'd
	  allow_opts			:: #lcp_opts{},			%% Options we allow peer to request
	  his_opts			:: #lcp_opts{}			%% Options that we ack'd
	 }).

%%%===================================================================
%%% Protocol API
%%%===================================================================

start_link(Link, Config) ->
    ppp_fsm:start_link(Link, Config, ?MODULE).

lowerup(FSM) ->
    ppp_fsm:fsm_lowerup(FSM).

lowerdown(FSM) ->
    ppp_fsm:fsm_lowerdown(FSM).

loweropen(FSM) ->
    ppp_fsm:fsm_loweropen(FSM).

lowerclose(FSM, Reason) ->
    ppp_fsm:fsm_lowerclose(FSM, Reason).

frame_in(FSM, Frame) ->
    ppp_fsm:fsm_frame_in(FSM, Frame).

%%===================================================================
%% ppp_fsm callbacks
%%===================================================================

%% fsm events

handler_lower_event(Event, FSMState, State) ->
    %% do somthing
    ppp_fsm:handler_lower_event(Event, FSMState, State).

%% fsm callback

init(Link, Config) ->
    WantOpts = #lcp_opts{
      neg_mru = true,
      mru = ?DEFMRU,
      neg_asyncmap = true,
      neg_magicnumber = true,
      neg_pcompression = true,
      neg_accompression = true
     },

    AllowOpts = #lcp_opts{
      neg_mru = true,
      mru = ?MAXMRU,
      neg_asyncmap = true,
      neg_auth = [eap, {chap, ?CHAP_ALL_AUTH}, pap],
      neg_magicnumber = true,
      neg_pcompression = true,
      neg_accompression = true,
      neg_endpoint = true
     },

%% TODO: apply config to want_opts and allow_opts

    FsmConfig = #fsm_config{
      passive = proplists:get_bool(passive, Config),
      silent = proplists:get_bool(silent, Config),
%%      restart = proplists:get_bool(restart, Config),
      term_restart_count = proplists:get_value(lcp_max_terminate, Config, 2),
      conf_restart_count = proplists:get_value(lcp_max_configure, Config, 10),
      failure_count = proplists:get_value(lcp_max_failure, Config, 5),
      restart_timeout = proplists:get_value(lcp_restart, Config, 3000)
     },

    {ok, lcp, FsmConfig, #state{link = Link, config = Config, want_opts = WantOpts, allow_opts = AllowOpts}}.

resetci(State = #state{want_opts = WantOpts}) ->
    WantOpts1 = WantOpts#lcp_opts{magicnumber = random:uniform(16#ffffffff)},
    NewState = State#state{want_opts = WantOpts1, got_opts = WantOpts1},
    auth_reset(NewState).

auth_reset(State = #state{got_opts = GotOpts}) ->
%% TODO:
%%   select auth schemes based on availabe secrets and config
%%
    GotOpts1 = GotOpts#lcp_opts{neg_auth = [eap, {chap, ?CHAP_ALL_AUTH}, pap]},
    State#state{got_opts = GotOpts1}.

addci(_StateName, State = #state{got_opts = GotOpts}) ->
    Options = lcp_addcis(GotOpts),
    {Options, State}.

ackci(_StateName, Options, State = #state{got_opts = GotOpts}) ->
    Reply = lcp_ackcis(Options, GotOpts),
    {Reply, State}.

nakci(StateName, Options, _TreatAsReject,
      State = #state{got_opts = GotOpts, want_opts = WantOpts}) ->
    DoUpdate = StateName /= opened,
    case lcp_nakcis(Options, GotOpts, WantOpts, GotOpts, #lcp_opts{}) of
	TryOpts when is_record(TryOpts, lcp_opts) ->
	    if
		DoUpdate -> {true, State#state{got_opts = TryOpts}};
		true     -> {true, State}
	    end;
	Other -> {false, Other}
    end.

rejci(StateName, Options, State = #state{got_opts = GotOpts}) ->
    DoUpdate = StateName /= opened,
    case lcp_rejcis(Options, GotOpts, GotOpts) of
	TryOpts when is_record(TryOpts, lcp_opts) ->
	    if
		DoUpdate -> {true, State#state{got_opts = TryOpts}};
		true     -> {true, State}
	    end;
	Other -> {false, Other}
    end.

reqci(_StateName, Options, RejectIfDisagree,
      State = #state{got_opts = GotOpts, allow_opts = AllowedOpts}) ->
    {{Verdict, ReplyOpts}, HisOpts} = process_reqcis(Options, RejectIfDisagree, AllowedOpts, GotOpts),
    ReplyOpts1 = lists:reverse(ReplyOpts),
    NewState = State#state{his_opts = HisOpts},
    {{Verdict, ReplyOpts1}, NewState}.

up(State = #state{got_opts = GotOpts, his_opts = HisOpts}) ->
    io:format("~p: Up~n", [?MODULE]),
    %% Link is ready,
    %% set MRU, MMRU, ASyncMap and Compression options on Link
    %% Enable LCP Echos
    %% Set Link Up
    Reply = {up, GotOpts, HisOpts},
    {Reply, State}.

down(State) ->
    io:format("~p: Down~n", [?MODULE]),
    %% Disable LCP Echos
    %% Set Link Down
    {down, State}.

starting(State) ->
    io:format("~p: Starting~n", [?MODULE]),
    %%link_required(f->unit);
    {starting, State}.


finished(State) ->
    io:format("~p: Finished~n", [?MODULE]),
    %% link_terminated(f->unit);
    {terminated, State}.

%%===================================================================
%% Option Generation
-define(AUTH_OPTS_R, [pap, chap, eap]).
-define(LCP_OPTS, [mru , asyncmap, auth, quality, callback, magic, pfc, acfc, mrru, epdisc, ssnhf]).

-spec lcp_addci(AddOpt :: atom(),
		GotOpts :: #lcp_opts{}) -> ppp_option().

lcp_addci(mru, #lcp_opts{neg_mru = true, mru = GotMRU})
  when GotMRU /= ?DEFMRU ->
    {mru, GotMRU};

lcp_addci(asyncmap, #lcp_opts{neg_asyncmap = true, asyncmap = GotACCM})
  when GotACCM /= 16#ffffffff ->
    {asyncmap, GotACCM};
    
lcp_addci(auth, #lcp_opts{neg_auth = GotAuth})
  when is_list(GotAuth) ->
    suggest_auth(GotAuth);

lcp_addci(auth, #lcp_opts{neg_auth = GotAuth}) ->
    io:format("lcp_addci: skiping auth: ~p~n", [GotAuth]),
    [];

lcp_addci(quality, #lcp_opts{neg_lqr = true, lqr_period = GotPeriod}) ->
    {quality, ?PPP_LQR, GotPeriod};

lcp_addci(callback, #lcp_opts{neg_cbcp = true}) ->
    {callback, ?CBCP_OPT};

lcp_addci(magic, #lcp_opts{neg_magicnumber = true, magicnumber = GotMagic}) ->
    {magic, GotMagic};

lcp_addci(pfc, #lcp_opts{neg_pcompression = true}) ->
    pfc;

lcp_addci(acfc, #lcp_opts{neg_accompression = true}) ->
    acfc;

lcp_addci(mrru, #lcp_opts{neg_mrru = true, mrru = GotMRRU}) ->
    {mrru, GotMRRU};

lcp_addci(ssnhf, #lcp_opts{neg_ssnhf = true}) ->
    ssnhf;

lcp_addci(epdisc,
	  #lcp_opts{neg_endpoint = true, endpoint =
			#epdisc{class = GotClass, address = GotAddress}}) ->
    {epdisc, GotClass, GotAddress};

lcp_addci(_, _) ->
    [].

lcp_addcis(GotOpts) ->
    [lcp_addci(Opt, GotOpts) || Opt <- ?LCP_OPTS].

%%===================================================================
%% Option Validations
-spec lcp_nakci(NakOpt :: ppp_option(),
		GotOpts :: #lcp_opts{},
		WantOpts :: #lcp_opts{},
		TryOpts :: #lcp_opts{},
		NakOpts :: #lcp_opts{}) -> {#lcp_opts{}, #lcp_opts{}}.

%%
%% We don't care if they want to send us smaller packets than
%% we want.  Therefore, accept any MRU less than what we asked for,
%% but then ignore the new value when setting the MRU in the kernel.
%% If they send us a bigger MRU than what we asked, accept it, up to
%% the limit of the default MRU we'd get if we didn't negotiate.
%%
lcp_nakci({mru, NakMRU}, GotOpts = #lcp_opts{neg_mru = true}, WantOpts, TryOpts, NakOpts)
  when GotOpts#lcp_opts.mru /= ?DEFMRU ->
    T1 = if NakMRU =< WantOpts#lcp_opts.mru orelse NakMRU =< ?DEFMRU ->
		 TryOpts#lcp_opts{mru = NakMRU};
	    true -> TryOpts
	 end,
    N1 = NakOpts#lcp_opts{neg_mru = true},
    {T1, N1};

lcp_nakci({mru, NakMRU}, GotOpts = #lcp_opts{neg_mru = GotNegMRU}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_mru = false})
  when not (GotNegMRU and GotOpts#lcp_opts.mru /= ?DEFMRU) ->
    T1 = if NakMRU =< ?DEFMRU ->
		 TryOpts#lcp_opts{mru = NakMRU};
	    true -> TryOpts
	 end,
    N1 = NakOpts#lcp_opts{neg_mru = true},
    {T1, N1};

%%
%% Add any characters they want to our (receive-side) asyncmap.
%%
lcp_nakci({asyncmap, NakACCM}, #lcp_opts{neg_asyncmap = true, asyncmap = GotACCM}, _WantOpts, TryOpts, NakOpts)
  when GotACCM /= 16#ffffffff ->
    T1 = TryOpts#lcp_opts{asyncmap = GotACCM bor NakACCM},
    N1 = NakOpts#lcp_opts{neg_asyncmap = true},
    {T1, N1};

lcp_nakci({asyncmap, _}, #lcp_opts{neg_asyncmap = GotNegACCM, asyncmap = GotACCM}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_asyncmap = false})
  when not (GotNegACCM and GotACCM /= 16#ffffffff) ->
    N1 = NakOpts#lcp_opts{neg_asyncmap = true},
    {TryOpts, N1};

%%
%% If they've nak'd our authentication-protocol, check whether
%% they are proposing a different protocol, or a different
%% hash algorithm for CHAP.
%%
lcp_nakci({auth, NakAuth, _}, #lcp_opts{neg_auth = GotAuth}, _WantOpts, TryOpts, NakOpts)
  when NakAuth == eap; NakAuth == pap ->
    case GotAuth of
	[NakAuth|_] ->
	    false;
	[LastAuth|TryAuth] ->
	    T1 = TryOpts#lcp_opts{neg_auth = TryAuth},
	    io:format("neg_auth: ~p~n", [NakOpts#lcp_opts.neg_auth]),
	    io:format("NakAuth: ~p~n", [NakAuth]),
	    N1 = NakOpts#lcp_opts{neg_auth = NakOpts#lcp_opts.neg_auth ++ [LastAuth]},
	    {T1, N1}
    end;

lcp_nakci({auth, NakAuth, NakMDType}, #lcp_opts{neg_auth = GotAuth}, _WantOpts, TryOpts, NakOpts)
  when NakAuth == chap ->
    case GotAuth of
	[{NakAuth, [NakMDType|_]}|_] ->
	    %% Whoops, they Nak'd our algorithm of choice
	    %% but then suggested it back to us.
	    false;
	[LastAuth|RestAuth] ->
	    case LastAuth of
		{chap, _} -> NextAuth = LastAuth;
		_         -> NextAuth = RestAuth
		end,
	    TryMDTypes = suggest_md_type(NakMDType, proplists:get_value(NakAuth, NextAuth)),
	    TryAuth = lists:keyreplace(NakAuth, 1, NextAuth, {NakAuth, TryMDTypes}),
	    T1 = TryOpts#lcp_opts{neg_auth = TryAuth},

	    %% FIXME: too simplistic..
	    N1 = NakOpts#lcp_opts{neg_auth = NakOpts#lcp_opts.neg_auth ++ [NakAuth]},
	    {T1, N1}
    end;

lcp_nakci({auth, NakAuth, _}, #lcp_opts{neg_auth = []}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_auth = []}) ->
    N1 = NakOpts#lcp_opts{neg_auth = NakOpts#lcp_opts.neg_auth ++ NakAuth},
    {TryOpts, N1};

lcp_nakci({quality, NakQR, NakPeriod}, #lcp_opts{neg_lqr = true}, _WantOpts, TryOpts, NakOpts) ->
    if NakQR /= ?PPP_LQR -> 
	    T1 = TryOpts#lcp_opts{neg_lqr = false};
       true ->
	    T1 = TryOpts#lcp_opts{lqr_period = NakPeriod}
    end,
    N1 = NakOpts#lcp_opts{neg_lqr = true},
    {T1, N1};

lcp_nakci({quality, _, _}, #lcp_opts{neg_lqr = false}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_lqr = false}) ->
    N1 = NakOpts#lcp_opts{neg_lqr = true},
    {TryOpts, N1};

lcp_nakci({callback, ?CBCP_OPT}, #lcp_opts{neg_cbcp = true}, _WantOpts, TryOpts, NakOpts) ->
    T1 = TryOpts#lcp_opts{neg_cbcp = false},
    N1 = NakOpts#lcp_opts{neg_cbcp = true},
    {T1, N1};

lcp_nakci({magic, _}, #lcp_opts{neg_magicnumber = true}, _WantOpts, TryOpts, NakOpts) ->
    T1 = TryOpts#lcp_opts{magicnumber = random:uniform(16#ffffffff)},
    N1 = NakOpts#lcp_opts{neg_magicnumber = true},
    {T1, N1};

lcp_nakci({magic, _}, #lcp_opts{neg_magicnumber = false}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_magicnumber = false}) ->
    N1 = NakOpts#lcp_opts{neg_magicnumber = true},
    {TryOpts, N1};

%% Peer shouldn't send Nak for protocol compression or
%% address/control compression requests; they should send
%% a Reject instead.  If they send a Nak, treat it as a Reject.
lcp_nakci(pfc, #lcp_opts{neg_pcompression = true}, _WantOpts, TryOpts, NakOpts) ->
    N1 = NakOpts#lcp_opts{neg_pcompression = true},
    {TryOpts, N1};

lcp_nakci(pfc, #lcp_opts{neg_pcompression = false}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_pcompression = false}) ->
    N1 = NakOpts#lcp_opts{neg_pcompression = true},
    {TryOpts, N1};

lcp_nakci(acfc, #lcp_opts{neg_accompression = true}, _WantOpts, TryOpts, NakOpts) ->
    N1 = NakOpts#lcp_opts{neg_accompression = true},
    {TryOpts, N1};

lcp_nakci(acfc, #lcp_opts{neg_accompression = false}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_accompression = false}) ->
    N1 = NakOpts#lcp_opts{neg_accompression = true},
    {TryOpts, N1};

lcp_nakci({mrru, NakMRRU}, #lcp_opts{neg_mrru = true}, WantOpts, TryOpts, NakOpts) ->
    if NakMRRU < WantOpts#lcp_opts.mrru ->
	    T1 = TryOpts#lcp_opts{mrru = NakMRRU};
       true ->
	    T1 = TryOpts
    end,
    N1 = NakOpts#lcp_opts{neg_mrru = true},
    {T1, N1};

lcp_nakci({mrru, _}, #lcp_opts{neg_mrru = false}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_mrru = false}) ->
    N1 = NakOpts#lcp_opts{neg_mrru = true},
    {TryOpts, N1};

%% Nak for short sequence numbers shouldn't be sent, treat it
%% like a reject.
lcp_nakci(ssnhf, #lcp_opts{neg_ssnhf = true}, _WantOpts, TryOpts, NakOpts) ->
    N1 = NakOpts#lcp_opts{neg_ssnhf = true},
    {TryOpts, N1};

lcp_nakci(ssnhf, #lcp_opts{neg_ssnhf = false}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_ssnhf = false}) ->
    N1 = NakOpts#lcp_opts{neg_ssnhf = true},
    {TryOpts, N1};

%% Nak of the endpoint discriminator option is not permitted,
%% treat it like a reject.
lcp_nakci({epdisc, _, _}, #lcp_opts{neg_endpoint = true}, _WantOpts, TryOpts, NakOpts) ->
    N1 = NakOpts#lcp_opts{neg_endpoint = true},
    {TryOpts, N1};

lcp_nakci({epdisc, _, _}, #lcp_opts{neg_endpoint = false}, _WantOpts, TryOpts, NakOpts = #lcp_opts{neg_endpoint = false}) ->
    N1 = NakOpts#lcp_opts{neg_endpoint = true},
    {TryOpts, N1};

lcp_nakci(_, _, _, _, _) ->
    false.

%% drop the first (currently prefered) because it has been rejected
suggest_md_type(Prefered, [_|Available]) ->
    case proplists:get_bool(Prefered, Available) of
	true ->
	    [Prefered|proplists:delete(Prefered, Available)];
	false -> Available
    end.

%%TODO: does this really matter?
%%
%% RFC1661 says:
%%   Options from the Configure-Request MUST NOT be reordered
%% we do not enforce ordering here, pppd does
%%
%% Note: on generating Ack/Naks we do preserve ordering!
%%
lcp_nakcis([], _, _, TryOpts, _) ->
    io:format("lcp_nakcis: ~p~n", [TryOpts]),
    TryOpts;
lcp_nakcis([Opt|Options], GotOpts, WantOpts, TryOpts, NakOpts) ->
    case lcp_nakci(Opt, GotOpts, WantOpts, TryOpts, NakOpts) of
	{NewTryOpts, NewNakOpts} ->
	    lcp_nakcis(Options, GotOpts, WantOpts, NewTryOpts, NewNakOpts);
	_ ->
	    io:format("lcp_nakcis: received bad Nakt!~n"),
	    false
    end.

-spec lcp_rejci(RejOpt :: ppp_option(),
		GotOpts :: #lcp_opts{},
		TryOpts :: #lcp_opts{}) -> #lcp_opts{}.

lcp_rejci({mru, MRU}, #lcp_opts{neg_mru = true, mru = MRU}, TryOpts) ->
    TryOpts#lcp_opts{neg_mru = false};

lcp_rejci({asyncmap, ACCM}, #lcp_opts{neg_asyncmap = true, asyncmap = ACCM}, TryOpts) ->
    TryOpts#lcp_opts{neg_asyncmap = false};

lcp_rejci({auth, RejAuth, _}, #lcp_opts{neg_auth = GotAuth}, TryOpts = #lcp_opts{neg_auth = TryAuth})
  when RejAuth == pap; RejAuth == eap ->
    case proplists:get_bool(RejAuth, GotAuth) of
	true -> TryOpts#lcp_opts{neg_auth = proplists:delete(RejAuth, TryAuth)};
	_    -> false
    end;

lcp_rejci({auth, RejAuth, RejMDType}, #lcp_opts{neg_auth = GotAuth}, TryOpts = #lcp_opts{neg_auth = TryAuth})
  when RejAuth == chap ->
    case proplists:get_value(RejAuth, GotAuth) of
	[RejMDType] ->
	    %% last CHAP MD
	    TryOpts#lcp_opts{neg_auth = proplists:delete(RejAuth, TryAuth)};
	TryMDType when is_list(TryMDType) ->
	    case proplists:get_bool(RejMDType, TryMDType) of
		true ->
		    NewTryMDType = proplists:delete(RejMDType, TryMDType),
		    TryOpts#lcp_opts{neg_auth = lists:keyreplace(RejAuth, 1, TryAuth, NewTryMDType)};
		_ ->
		    false
	    end
    end;

lcp_rejci({quality, ?PPP_LQR, Period}, #lcp_opts{neg_lqr = true, lqr_period = Period}, TryOpts) ->
    TryOpts#lcp_opts{neg_lqr = false};

lcp_rejci({callback, ?CBCP_OPT}, #lcp_opts{neg_cbcp = true}, TryOpts) ->
    TryOpts#lcp_opts{neg_cbcp = false};

lcp_rejci({magic, Magic}, #lcp_opts{neg_magicnumber = true, magicnumber = Magic}, TryOpts) ->
    TryOpts#lcp_opts{neg_magicnumber = false};

lcp_rejci(pfc, #lcp_opts{neg_pcompression = true}, TryOpts) ->
    TryOpts#lcp_opts{neg_pcompression = false};

lcp_rejci(acfc, #lcp_opts{neg_accompression = true}, TryOpts) ->
    io:format("acfs rejected~n"),
    TryOpts#lcp_opts{neg_accompression = false};

lcp_rejci({mrru, MRRU}, #lcp_opts{neg_mrru = true, mrru = MRRU}, TryOpts) ->
    TryOpts#lcp_opts{neg_mrru = false};

lcp_rejci(ssnhf, #lcp_opts{neg_ssnhf = true}, TryOpts) ->
    TryOpts#lcp_opts{neg_ssnhf = false};

lcp_rejci({epdisc, Class, Address},
	       #lcp_opts{neg_endpoint = true, endpoint =
			     #epdisc{class = Class, address = Address}}, TryOpts) ->
    TryOpts#lcp_opts{neg_endpoint = false};

lcp_rejci(_, _, _) ->
    false.

%%TODO: does this really matter?
%%
%% RFC1661 says:
%%   Options from the Configure-Request MUST NOT be reordered
%% we do not enforce ordering here, pppd does
%%
%% Note: on generating Ack/Naks we do preserve ordering!
%%
lcp_rejcis([], _, TryOpts) ->
    TryOpts;
lcp_rejcis([RejOpt|RejOpts], GotOpts, TryOpts) ->
    case lcp_rejci(RejOpt, GotOpts, TryOpts) of
	NewTryOpts when is_record(NewTryOpts, lcp_opts) ->
	    lcp_rejcis(RejOpts, GotOpts, NewTryOpts);
	_ ->
	    io:format("lcp_rejcis: received bad Reject!~n"),
	    false
    end.

-spec lcp_ackci(AckOpt :: ppp_option(),
		     GotOpts :: #lcp_opts{}) -> true | false.

lcp_ackci({mru, AckMRU}, #lcp_opts{neg_mru = GotIt, mru = GotMRU})
  when GotMRU /= ?DEFMRU ->
    GotIt and (AckMRU == GotMRU);

lcp_ackci({asyncmap, AckACCM}, #lcp_opts{neg_asyncmap = GotIt, asyncmap = GotACCM})
  when GotACCM /= 16#ffffffff ->
    GotIt and (AckACCM == GotACCM);
    
lcp_ackci({auth, AckAuth, _}, #lcp_opts{neg_auth = GotAuth})
  when AckAuth == pap; AckAuth == eap ->
    io:format("AckAuth: ~p~n", [AckAuth]),
    io:format("GotAuth: ~p~n", [GotAuth]),
    proplists:get_bool(AckAuth, GotAuth);
lcp_ackci({auth, AckAuth, AckMDType}, #lcp_opts{neg_auth = GotAuth})
  when AckAuth == chap ->
    case GotAuth of
	[{AckAuth, [AckMDType|_]}|_] ->
	    true;
	_ ->
	    false
    end;

lcp_ackci({quality, AckQP, AckPeriod}, #lcp_opts{neg_lqr = GotIt, lqr_period = GotPeriod}) ->
    GotIt and (AckQP == ?PPP_LQR) and (AckPeriod == GotPeriod);

lcp_ackci({callback, Opt}, #lcp_opts{neg_cbcp = GotIt}) ->
    GotIt and (Opt == ?CBCP_OPT);

lcp_ackci({magic, AckMagic}, #lcp_opts{neg_magicnumber = GotIt, magicnumber = GotMagic}) ->
    GotIt and (AckMagic == GotMagic);

lcp_ackci(pfc, #lcp_opts{neg_pcompression = GotIt}) ->
    GotIt;

lcp_ackci(acfc, #lcp_opts{neg_accompression = GotIt}) ->
    GotIt;

lcp_ackci({mrru, AckMRRU}, #lcp_opts{neg_mrru = GotIt, mrru = GotMRRU}) ->
    GotIt and (AckMRRU == GotMRRU);

lcp_ackci(ssnhf, #lcp_opts{neg_ssnhf = GotIt}) ->
    GotIt;

lcp_ackci({epdisc, AckClass, AckAddress},
	       #lcp_opts{neg_endpoint = GotIt, endpoint =
			     #epdisc{class = GotClass, address = GotAddress}}) ->
    GotIt and (AckClass == GotClass) and (AckAddress == GotAddress);
lcp_ackci(Ack, _) ->
    io:format("invalid Ack: ~p~n", [Ack]),
    false.

%%TODO: does this really matter?
%%
%% RFC1661 says:
%%   Options from the Configure-Request MUST NOT be reordered
%% we do not enforce ordering here, pppd does
%%
%% Note: on generating Ack/Naks we do preserve ordering!
%%
lcp_ackcis([], _) ->
    true;
lcp_ackcis([AckOpt|AckOpts], GotOpts) ->
    case lcp_ackci(AckOpt, GotOpts) of
	false ->
	    io:format("lcp_ackcis: received bad Ack! ~p, ~p~n", [AckOpt, GotOpts]),
	    false;
	_ ->
	    lcp_ackcis(AckOpts, GotOpts)
    end.

-spec lcp_reqci(ReqOpt :: ppp_option(),
		     AllowedOpts :: #lcp_opts{},
		     GotOpts :: #lcp_opts{},
		     HisOpts :: #lcp_opts{}) ->
			    {Verdict :: atom() | {atom() | ppp_option()}, HisOptsNew :: #lcp_opts{}}.

lcp_reqci({mru, ReqMRU}, #lcp_opts{neg_mru = true}, _, HisOpts) ->
    if
	ReqMRU < ?MINMRU ->
	    Verdict = {nack, {mru, ?MINMRU}},
	    HisOptsNew = HisOpts;
	true -> 
	    Verdict = ack,
	    HisOptsNew = HisOpts#lcp_opts{neg_mru = true, mru = ReqMRU}
    end,
    {Verdict, HisOptsNew};

lcp_reqci({asyncmap, ReqACCM}, #lcp_opts{neg_asyncmap = true, asyncmap = AllowedACCM}, _, HisOpts) ->
    if
	%% Asyncmap must have set at least the bits
	%% which are set in AllowedOpts#lcp_opts.asyncmap

	AllowedACCM band bnot ReqACCM /= 0 ->
	    Verdict = {nack, {asyncmap, AllowedACCM bor ReqACCM}},
	    HisOptsNew = HisOpts;
	true -> 
	    Verdict = ack,
	    HisOptsNew = HisOpts#lcp_opts{neg_asyncmap = true, asyncmap = ReqACCM}
    end,
    {Verdict, HisOptsNew};

lcp_reqci({auth, _, _}, #lcp_opts{neg_auth = PermitedAuth}, _, HisOpts)
  when not is_list(PermitedAuth) orelse PermitedAuth == [] ->
    io:format("No auth is possible~n"),
    {rej, HisOpts};

%% Authtype must be PAP, CHAP, or EAP.
%%
%% Note: if more than one of ao->neg_upap, ao->neg_chap, and
%% ao->neg_eap are set, and the peer sends a Configure-Request
%% with two or more authenticate-protocol requests, then we will
%% reject the second request.
%% Whether we end up doing CHAP, UPAP, or EAP depends then on
%% the ordering of the CIs in the peer's Configure-Request.

lcp_reqci({auth, ReqAuth, _}, _, _, HisOpts = #lcp_opts{neg_auth = HisAuth})
  when HisAuth /= none ->
    io:format("lcp_reqci: rcvd AUTHTYPE ~p, rejecting...~n", [ReqAuth]),
    {rej, HisOpts};
lcp_reqci({auth, ReqAuth, _}, #lcp_opts{neg_auth = PermitedAuth}, _, HisOpts)
  when ReqAuth == pap; ReqAuth == eap ->
    case proplists:get_bool(ReqAuth, PermitedAuth) of
	true ->
	    Verdict = ack,
	    HisOptsNew = HisOpts#lcp_opts{neg_auth = ReqAuth};
	_ ->
	    Verdict = {nack, suggest_auth(PermitedAuth)},
	    HisOptsNew = HisOpts
    end,
    {Verdict, HisOptsNew};

lcp_reqci({auth, ReqAuth, ReqMDType}, #lcp_opts{neg_auth = PermitedAuth}, _, HisOpts)
  when ReqAuth == chap ->
    case proplists:get_value(ReqAuth, PermitedAuth) of
	 PermiteMDTypes when is_list(PermiteMDTypes) andalso PermiteMDTypes /= [] ->
	    case proplists:get_bool(ReqMDType, PermiteMDTypes) of
		true ->
		    Verdict = ack,
		    HisOptsNew = HisOpts#lcp_opts{neg_auth = {ReqAuth, ReqMDType}};
		_ ->
		    Verdict = {nack, suggest_auth(proplists:delete(chap, PermitedAuth))},
		    HisOptsNew = HisOpts
		end;
	_ ->
	    Verdict = {nack, suggest_auth(proplists:delete(chap, PermitedAuth))},
	    HisOptsNew = HisOpts
    end,
    {Verdict, HisOptsNew};

lcp_reqci({quality, ReqQP, ReqData}, #lcp_opts{neg_lqr = true, lqr_period = Period}, #lcp_opts{}, HisOpts = #lcp_opts{}) ->
    if
	ReqQP == ?PPP_LQR ->
	    Verdict = ack,
	    HisOptsNew = HisOpts#lcp_opts{neg_lqr = true, lqr_period = ReqData};
	true ->
	    Verdict = {nack, {quality, ?PPP_LQR, Period}},
	    HisOptsNew = HisOpts
    end,
    {Verdict, HisOptsNew};

lcp_reqci({magic, ReqMagic},
	       #lcp_opts{neg_magicnumber = AllowedNeg},
	       #lcp_opts{neg_magicnumber = GotNeg, magicnumber = GotMagic},
	       HisOpts = #lcp_opts{})
  when AllowedNeg == true; GotNeg == true ->
    if
	GotNeg andalso ReqMagic == GotMagic ->
	    Verdict = {rej, {magic, random:uniform(16#ffffffff)}},
	    HisOptsNew = HisOpts;
	true ->
	    Verdict = ack,
	    HisOptsNew = HisOpts#lcp_opts{neg_magicnumber = true, magicnumber = ReqMagic}
    end,
    {Verdict, HisOptsNew};

lcp_reqci(pfc, #lcp_opts{neg_pcompression = true}, _, HisOpts) ->
    Verdict = ack,
    HisOptsNew = HisOpts#lcp_opts{neg_pcompression = true},
    {Verdict, HisOptsNew};

lcp_reqci(acfc, #lcp_opts{neg_accompression = true}, _, HisOpts) ->
    Verdict = ack,
    HisOptsNew = HisOpts#lcp_opts{neg_accompression = true},
    {Verdict, HisOptsNew};

%% TODO: multilink check
lcp_reqci({mrru, ReqMRRU}, #lcp_opts{neg_mrru = true}, _, HisOpts) ->
    Verdict = ack,
    HisOptsNew = HisOpts#lcp_opts{neg_mrru = true, mrru = ReqMRRU},
    {Verdict, HisOptsNew};

lcp_reqci(ssnhf, #lcp_opts{neg_ssnhf = true}, _, HisOpts) ->
    Verdict = ack,
    HisOptsNew = HisOpts#lcp_opts{neg_ssnhf = true},
    {Verdict, HisOptsNew};

lcp_reqci({epdisc, ReqClass, ReqAddress}, #lcp_opts{neg_endpoint = true}, _, HisOpts) ->
    Verdict = ack,
    HisOptsNew = HisOpts#lcp_opts{neg_endpoint = true, endpoint = #epdisc{class = ReqClass, address = ReqAddress}},
    {Verdict, HisOptsNew};

lcp_reqci(Req, _, _, HisOpts) ->
    io:format("lcp_reqci: rejecting: ~p~n", [Req]),
    io:format("His: ~p~n", [HisOpts]),
    {rej, HisOpts}.

suggest_auth(PermitedAuths) ->
    suggest_auth(PermitedAuths, [eap, chap, pap]).
suggest_auth(_, []) ->
    [];
suggest_auth(PermitedAuths, [Auth|Rest]) ->
    case proplists:get_value(Auth, PermitedAuths, false) of
	false ->
	    suggest_auth(PermitedAuths, Rest);
	true ->
	    {auth, Auth, none};
	PermiteMDTypes when is_list(PermiteMDTypes) ->
	    suggest_chap(PermiteMDTypes)
    end.

suggest_chap([]) ->
    [];
suggest_chap([MDType|_]) ->
    {auth, chap, MDType}.

process_reqcis(Options, RejectIfDisagree, AllowedOpts, GotOpts) ->
    process_reqcis(Options, RejectIfDisagree, AllowedOpts, GotOpts, #lcp_opts{}, [], [], []).

process_reqcis([], _RejectIfDisagree, _AllowedOpts, _GotOpts, HisOpts, AckReply, NackReply, RejReply) ->
    Reply = if
		length(RejReply) /= 0 -> {rej, RejReply};
		length(NackReply) /= 0 -> {nack, NackReply};
		true -> {ack, AckReply}
	    end,
    {Reply, HisOpts};

process_reqcis([Opt|Options], RejectIfDisagree, AllowedOpts, GotOpts, HisOpts, AckReply, NAckReply, RejReply) ->
    {Verdict, HisOptsNew} = lcp_reqci(Opt, AllowedOpts, GotOpts, HisOpts),
    case Verdict of
	ack ->
	    process_reqcis(Options, RejectIfDisagree, AllowedOpts, GotOpts, HisOptsNew, [Opt|AckReply], NAckReply, RejReply);
	{nack, _} when RejectIfDisagree ->
	    process_reqcis(Options, RejectIfDisagree, AllowedOpts, GotOpts, HisOptsNew, AckReply, NAckReply, [Opt|RejReply]);
	{nack, NewOpt} ->
	    process_reqcis(Options, RejectIfDisagree, AllowedOpts, GotOpts, HisOptsNew, AckReply, [NewOpt|NAckReply], RejReply);
	rej ->
	    process_reqcis(Options, RejectIfDisagree, AllowedOpts, GotOpts, HisOptsNew, AckReply, NAckReply, [Opt|RejReply])
    end.