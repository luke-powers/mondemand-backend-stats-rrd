-module (mondemand_backend_stats_rrd_tcp).

-behaviour (supervisor).
-behaviour (mondemand_server_backend).
-behaviour (mondemand_backend_worker).
-behaviour (mondemand_backend_stats_handler).

%% mondemand_server_backend callbacks
-export ([ start_link/1,
           process/1,
           required_apps/0,
           type/0
         ]).

%% mondemand_backend_worker callbacks
-export ([ create/1,
           connected/1,
           connect/1,
           send/2,
           destroy/1
         ]).

%% mondemand_backend_stats_handler callbacks
-export ([ header/0,
           separator/0,
           format_stat/10,
           footer/0,
           handle_response/2
         ]).

%% supervisor callbacks
-export ([init/1]).

-define (POOL, md_rrd_pool).
-record (state, { host,
                  port,
                  send_timeout,
                  recv_timeout,
                  connect_timeout,
                  connection
                }).

%%====================================================================
%% mondemand_server_backend callbacks
%%====================================================================
start_link (Config) ->
  supervisor:start_link ({local, ?MODULE}, ?MODULE, [Config]).

process (Event) ->
  mondemand_backend_worker_pool_sup:process (?POOL, Event).

required_apps () ->
  [ lager, erlrrd ].

type () ->
  supervisor.

%%====================================================================
%% supervisor callbacks
%%====================================================================
init ([Config]) ->
  Prefix = proplists:get_value (prefix, Config, "."),

  mondemand_server_util:mkdir_p (Prefix),

  % default to one process per scheduler
  Number = proplists:get_value (number, Config, erlang:system_info(schedulers)),

  FileNameCache =
    proplists:get_value (file_cache, Config, "/tmp/file_name_cache.ets"),
  HostDir =
    proplists:get_value (host_dir, Config, "md"),
  AggregateDir =
    proplists:get_value (aggregate_dir, Config, "agg"),

  { ok,
    {
      {one_for_one, 10, 10},
      [
        { mondemand_backend_stats_rrd_builder,
          { mondemand_backend_stats_rrd_builder, start_link,
            []
          },
          permanent,
          2000,
          worker,
          [ mondemand_backend_stats_rrd_builder]
        },
        { mondemand_backend_stats_rrd_filecache,
          { mondemand_backend_stats_rrd_filecache, start_link,
            [FileNameCache, HostDir, AggregateDir]
          },
          permanent,
          2000,
          worker,
          [ mondemand_backend_stats_rrd_filecache ]
        },
        { ?POOL,
          { mondemand_backend_worker_pool_sup, start_link,
            [ ?POOL,
              mondemand_backend_worker,
              Number,
              ?MODULE
            ]
          },
          permanent,
          2000,
          supervisor,
          [ ]
        }
      ]
    }
  }.

%%====================================================================
%% mondemand_backend_worker callbacks
%%====================================================================
create (Config) ->
  Host = proplists:get_value (host, Config, "127.0.0.1"),
  Port = proplists:get_value (port, Config, 11211),
  ConnectTimeout = proplists:get_value (connect_timeout, Config, 1000),
  SendTimeout = proplists:get_value (send_timeout, Config, 100),
  RecvTimeout = proplists:get_value (recv_timeout, Config, 50),

  io:format ("create ~p:~p (~p, ~p, ~p)~n",[Host, Port, ConnectTimeout, SendTimeout, RecvTimeout]),
  {ok, #state { host = Host,
                port = Port,
                connect_timeout = ConnectTimeout,
                send_timeout = SendTimeout,
                recv_timeout = RecvTimeout,
                connection = undefined
              }}.

connected (#state { connection = undefined }) -> false;
connected (_) -> true.

connect (State = #state { host = Host,
                          port = Port,
                          connect_timeout = ConnectTimeout,
                          send_timeout = SendTimeout,
                          recv_timeout = RecvTimeout
                        }) ->
  case rrdcached_client:open (Host, Port, ConnectTimeout,
                              SendTimeout, RecvTimeout) of
    {ok, Client} ->
      {ok, State#state { connection = Client }};
    Error ->
      {Error, State}
  end.

send (State = #state {connection = Client0}, Data) ->
  case rrdcached_client:batch_start (Client0) of
    {Client1, ok} ->
      case rrdcached_client:send_command (Client1, Data) of
        {Client2, ok} ->
          case rrdcached_client:batch_end (Client2) of
            {NewC, {status,0,"errors\n"}} ->
              {ok, State#state {connection = NewC}};
            {NewC, {error, ErrorList}} ->
              % mark all entries which had errors in the cache
              [
                case E of
                  {error, no_file} -> true;
                  _ ->
                    mondemand_backend_stats_rrd_filecache:mark_error (
                        rrdcached_client:file_from_command (C),
                        E )
                end
                || {C, E}
                <- ErrorList
              ],
              {ok, State#state {connection = NewC}};
            {NewC, _} ->
              {error, State#state {connection = NewC}}
          end;
        {NewClient2, _} ->
          { error, State#state {connection = NewClient2} }
      end;
    {NewClient1, _} ->
     {error, State#state {connection = NewClient1}}
  end.

destroy (#state {connection = Client}) ->
  rrdcached_client:close (Client).

%%====================================================================
%% mondemand_backend_stats_handler callbacks
%%====================================================================
header () -> undefined.

separator () -> undefined.

format_stat (_Num, _Total, Prefix, ProgId, Host,
             MetricType, MetricName, MetricValue, Timestamp, Context) ->
  { RRDFilePaths, Errors } =
    case MetricType of
      statset ->
        lists:foldl (
          fun ({SubType, SubTypeValue}, {Good, Bad}) ->
            case mondemand_backend_stats_rrd_filecache:check_cache
                   (Prefix,ProgId,{MetricType, SubType},
                    MetricName,Host,Context) of
              {ok, P} -> { Good ++ [ {P, SubTypeValue} ], Bad };
              {error, _} -> { Good, Bad + 1 }
            end
          end,
          {[], 0 },
          mondemand_statsmsg:statset_to_list (MetricValue)
        );
      _ ->
        case mondemand_backend_stats_rrd_filecache:check_cache
               (Prefix,ProgId,MetricType,MetricName,Host,Context) of
          {ok, P} -> { [{P, MetricValue}], 0};
          {error, _} -> { [], 1 }
        end
    end,

  case Errors > 0 of
    false -> ok;
    true ->
      error_logger:error_msg ("~b errors found while formatting",[Errors])
  end,

  Res =
    [
      begin
        Update = lists:flatten (io_lib:fwrite ("~b:~b", [Timestamp,Value])),
        rrdcached_client:update (P, Update)
      end
      || { P, Value }
      <- RRDFilePaths
    ],
  Res.

footer () -> undefined.

handle_response (_, _) ->
  ok.