%%%-------------------------------------------------------------------
%%% @author mihail
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 30. Апр. 2016 12:37
%%%-------------------------------------------------------------------
-module(teles_service_agent).
-author("mihail").

-behaviour(gen_server).

-include_lib("rstar/include/rstar.hrl").

%% API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-record(state, {
  id,         % Agent ID
  space,      % Name of the space, e.g. 'cities'

  objects,    % ETS table of objects in the space
  % Maps OID -> {Value, [#geometry]}

  geos,       % ETS table of geometries
  % Maps GID -> {Value, [OID]}

  rstar       % R*-tree index of geometries
}).

-record(object, {
  id,      % Object ID (OID)
  value,   % Opaque value
  geos=[]  % List of GID's
}).

-record(geo, {
  id,      % Geometry ID (GID)
  value,   % Opaque value
  rgeo,     % R-star Geometry
  objects=[]  % List of OID's
}).

% Timeout in MSEC for a state transfer
% to timeout. Default to 60 seconds.
-define(TRANSFER_TIMEOUT, 60000).

start_link(ID, Space) ->
  Name = list_to_atom(lists:flatten(io_lib:format("agent_~s_~p", [Space, ID]))),
  gen_server:start_link({local, Name}, ?MODULE, [ID, Space], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([ID, Space]) ->

  ObjectTable = ets:new(objects, []),
  GeoTable = ets:new(geometries, []),
  Rtree = rstar:new(2),
  State = #state{id=ID, space=Space, objects=ObjectTable,
    geos=GeoTable, rstar=Rtree},
  {ok, State}.

handle_call(list_objects, _From, State) ->
  Keys = ets:foldl(fun({Key, _Val}, Accum) ->
    [Key | Accum]
                   end, [], State#state.objects),
  {reply, {ok, Keys}, State};


handle_call({list_associations, Id}, _From, State) ->
  Table = State#state.objects,
  Resp = case ets:lookup(Table, Id) of
           [] -> not_found;
           [{Id, Obj}] ->
             % Convert the GID's to actual geometries
             GeoTable = State#state.geos,
             GeosRaw = lists:flatten(
               [element(2, lists:nth(1, ets:lookup(GeoTable, G)))||
                 G <- Obj#object.geos]),
             Geos = [{G#geo.id, G#geo.value, G#geo.rgeo} || G <- GeosRaw],

             {ok, Id, Obj#object.value, Geos}
         end,
  {reply, Resp, State};


handle_call({add_object, Id, Value}, _From, State) ->
  Table = State#state.objects,
  Obj = #object{id=Id, value=Value},

  % Use insert_new so we don't nuke existing entries
  ets:insert_new(Table, {Id, Obj}),
  {reply, ok, State};


handle_call({associate, Id, Lat, Lng, Value}, _From, State) ->
  Table = State#state.objects,
  {Resp, NewState} = case ets:lookup(Table, Id) of
                       [] -> {not_found, State};
                       [{Id, Obj}] ->
                         S1 = associate(Id, Obj, Lat, Lng, Value, State),
                         {ok, S1}
                     end,
  {reply, Resp, NewState};


handle_call({disassociate, OID, GID}, _From, State) ->
  ObjTable = State#state.objects,
  {Resp, NewState} = case ets:lookup(ObjTable, OID) of
                       [] -> {not_found, State};
                       [{OID, Obj}] ->
                         % Chck for a OID -> GID map
                         case lists:member(GID, Obj#object.geos) of
                           false -> {not_associated, State};
                           true ->
                             State1 = disassociate(OID, Obj, GID, State),
                             {ok, State1}
                         end
                     end,
  {reply, Resp, NewState};


handle_call({delete, OID}, _From, State) ->
  ObjTable = State#state.objects,
  {Resp, NewState} = case ets:lookup(ObjTable, OID) of
                       [] -> {not_found, State};
                       [{OID, Obj}] ->
                         % Remove all associations
                         State1 = lists:foldl(fun(GID, S) ->
                           disassociate(OID, Obj, GID, S)
                                              end, State, Obj#object.geos),

                         % Nuke the object
                         ets:delete(ObjTable, OID),
                         {ok, State1}
                     end,
  {reply, Resp, NewState};


handle_call({query_within, SearchBox}, _From, State) ->
  % Search the R-tree
  Tree = State#state.rstar,
  RGeos = rstar:search_within(Tree, SearchBox),

  % Resolve the unique OID's
  UniqueOIDs = unique_results(RGeos, State),
  {reply, {ok, UniqueOIDs}, State};


handle_call({query_around, SearchPoint, Distance}, _From, State) ->
  % Search the R-tree
  Tree = State#state.rstar,
  RGeos = teles_geo_query:search_around(Tree, SearchPoint, Distance),

  % Resolve the unique OID's
  UniqueOIDs = unique_results(RGeos, State),
  {reply, {ok, UniqueOIDs}, State};


handle_call({query_nearest, SearchPoint, K}, _From, State) ->
  % Search the R-tree
  Tree = State#state.rstar,
  RGeos = teles_geo_query:search_nearest(Tree, SearchPoint, K),

  % Resolve the unique OID's
  UniqueOIDs = unique_results(RGeos, State),
  {reply, {ok, UniqueOIDs}, State};


handle_call(state_transfer, _From, State) ->
  {reply, {ok, State}, State};


handle_call(stop, _From, State) ->
  {stop, normal, ok, State}.


handle_cast(stop, State) ->
  {stop, normal, State};

% Invoked when an agent is being recovered after a crash
handle_cast({recover, Manager, {Pid1, Pid2, _}}, State) ->
  % Get the siblings
  Siblings = lists:append(Pid1, Pid2),
  NS = case Siblings of
         [] -> lager:warning("No siblings available for recovery!"), State;
         [Sibling | _] ->
           % Log the attempt
           lager:info("Attempting recovery from agent ~p for ~p",
             [Sibling, State#state.id]),

           % Perform a state transfer
           {ok, OtherState} = gen_server:call(Sibling, state_transfer,
             ?TRANSFER_TIMEOUT),
           lager:info("State transfer from agent ~p complete", [Sibling]),

           % Clone the tables
           lager:info("Cloning objects from ~p", [Sibling]),
           clone_table(OtherState#state.objects, State#state.objects),
           lager:info("Cloning geometries from ~p", [Sibling]),
           clone_table(OtherState#state.geos, State#state.geos),

           % Merge in the Rtree as our updated state
           lager:info("Merging R-tree from ~p", [Sibling]),
           State#state{rstar=OtherState#state.rstar}
       end,

  % Notify the manager we are ready
  gen_server:cast(Manager, {ready, self(), State#state.space}),
  {noreply, NS}.


handle_info(_Info, State) ->
  {noreply, State}.


terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

% Clones one ETS table into a destination
clone_table(Src, Dest) ->
  ets:foldl(fun(Elem, _) ->
    ets:insert(Dest, Elem)
            end, true, Src).


% Makes a Rstar Geometry object from a Lat/Lng
make_geo(Lat, Lng) ->
  % Create a geo
  Geo = rstar_geometry:point2d(Lat, Lng, undefined),

  % Set the hash as the value
  Hash = erlang:phash2(Geo, 4294967295),
  Geo#geometry{value=Hash}.


% Returns the internal Geo object
% associated with the given Rstar Geometry
% Will create the objet if necessary
get_or_create(RGeo, Value, State) ->
  % Find a GID if it exists
  GID = RGeo#geometry.value,

  GeoTable = State#state.geos,
  case ets:lookup(GeoTable, GID) of
    [{GID, Geo}] -> {Geo, State};
    [] ->
      % Create the Geo entry
      NewGeo = #geo{id=GID,
        value=Value,
        rgeo=RGeo},
      ets:insert(GeoTable, {GID, NewGeo}),

      % Add to the R-tree
      Tree = State#state.rstar,
      NewTree = rstar:insert(Tree, RGeo),

      % Update the state
      {NewGeo, State#state{rstar=NewTree}}
  end.


% Associates an object with a lat/lng point
% Updating state as necessary
associate(Id, Obj, Lat, Lng, Value, State) ->
  % Get the GID
  RGeo = make_geo(Lat, Lng),
  GID = RGeo#geometry.value,

  % Check for an existing association
  case lists:member(GID, Obj#object.geos) of
    % Don't do anything, already associated
    true -> State;
    _ ->
      % Get the associated Geo of the GID
      {Geo, State1} = get_or_create(RGeo, Value, State),

      % Create the GID -> OID association
      GeoTable = State#state.geos,
      NewGeo = Geo#geo{objects=[Id | Geo#geo.objects]},
      ets:insert(GeoTable, {GID, NewGeo}),

      % Create the OID -> GID association
      ObjTable = State#state.objects,
      NewObj = Obj#object{geos=[GID | Obj#object.geos]},
      ets:insert(ObjTable, {Id, NewObj}),

      % Return the new state
      State1
  end.


disassociate(OID, Obj, GID, State) ->
  % Remove the OID -> GID mapping
  GIDS = Obj#object.geos -- [GID],
  NewObj = Obj#object{geos=GIDS},
  ObjTable = State#state.objects,
  ets:insert(ObjTable, {OID, NewObj}),

  % Remove the GID -> OID mapping
  GeoTable = State#state.geos,
  [{GID, Geo}] = ets:lookup(GeoTable, GID),
  OIDS = Geo#geo.objects -- [OID],

  % Check if we should delete the Geo
  case OIDS of
    % No objects for this
    [] ->
      ets:delete(GeoTable, GID),
      Tree = State#state.rstar,
      RGeo = Geo#geo.rgeo,
      NewTree = rstar:delete(Tree, RGeo),
      State#state{rstar=NewTree};

    % Other users of this geo
    _ ->
      NewGeo = Geo#geo{objects=OIDS},
      ets:insert(GeoTable, {GID, NewGeo}),
      State
  end.

% Returns the unique list of OID's that are associated
% with the geometries that are returned from a search
% of the R-star tree
unique_results(RGeos, State) ->
  % Resolve the mapped GID's
  GeoTable = State#state.geos,
  Geos = [element(2, lists:nth(1, ets:lookup(GeoTable, R#geometry.value)))
    || R <- RGeos],

  % Fold over each matching GID
  Matching = lists:foldl(fun(Geo, Matches) ->
    % Fold over each OID associated
    lists:foldl(fun(OID, M) ->
      sets:add_element(OID, M)
                end, Matches, Geo#geo.objects)
                         end, sets:new(), Geos),

  % Return the OIDS as a list
  sets:to_list(Matching).

