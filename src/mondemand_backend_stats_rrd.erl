-module (mondemand_backend_stats_rrd).

-behaviour (supervisor).
-behaviour (mondemand_server_backend).
-behaviour (mondemand_backend_stats_handler).

%% mondemand_server_backend callbacks
-export ([ start_link/1,
           process/1,
           required_apps/0,
           type/0
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

%%====================================================================
%% mondemand_server_backend callbacks
%%====================================================================
start_link (Config) ->
  supervisor:start_link ({local, ?MODULE}, ?MODULE, [Config]).

process (Event) ->
  mondemand_backend_worker_pool_sup:process
    (mondemand_backend_stats_rrd_worker_pool, Event).

required_apps () ->
  [ erlrrd ].

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

  { ok,
    {
      {one_for_one, 10, 10},
      [
        { mondemand_backend_stats_rrd_filecache,
          { mondemand_backend_stats_rrd_filecache, start_link,
            [FileNameCache]
          },
          permanent,
          2000,
          worker,
          [ mondemand_backend_stats_rrd_filecache ]
        },
        { mondemand_backend_stats_rrd_recent,
          { mondemand_backend_stats_rrd_recent, start_link, [] },
          permanent,
          2000,
          worker,
          [ mondemand_backend_stats_rrd_recent ]
        },
        { mondemand_backend_stats_rrd_worker_pool,
          { mondemand_backend_worker_pool_sup, start_link,
            [ mondemand_backend_stats_rrd_worker_pool,
              mondemand_backend_connection,
              Number,
              ?MODULE ]
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
%% mondemand_backend_stats_handler callbacks
%%====================================================================
header () -> "BATCH\n".

separator () -> "".

format_stat (_Num, _Total, Prefix, ProgId, Host,
             MetricType, MetricName, MetricValue, Timestamp, Context) ->

  { RRDFilePaths, Errors } =
    case MetricType of
      statset ->
        lists:mapfoldl (
          fun ({SubType, SubTypeValue}, HasErrors) ->
            case
              mondemand_backend_stats_rrd_filecache:check_cache
                (Prefix,ProgId,{MetricType, SubType},MetricName,Host,Context)
            of
              error -> { undefined, true };
              {ok, P} -> { {P, SubTypeValue}, HasErrors }
            end
          end,
          false,
          mondemand_statsmsg:statset_to_list (MetricValue)
        );
      _ ->
        case
          mondemand_backend_stats_rrd_filecache:check_cache
            (Prefix,ProgId,MetricType,MetricName,Host,Context)
        of
          error -> { undefined, true };
          {ok, P} -> { [{P, MetricValue}], false }
        end
    end,

  case Errors of
    true -> error;
    _ ->

% NOTE: this no longer works with restructuring
%      mondemand_backend_stats_rrd_recent:add (Num, Timestamp,
%                                              ProgId, MetricType,
%                                              MetricName, MetricValue,
%                                              Host, Context),
      [
        [ "UPDATE ", P, io_lib:fwrite (" ~b:~b\n", [Timestamp,Value])]
        || { P, Value }
        <- RRDFilePaths
      ]
  end.

footer () -> ".\n".

handle_response (Response, Previous) ->
  parse_response (Response, Previous).

-record (parse_state, {errors = 0, expected = 0, remaining}).

parse_response (Response, undefined) ->
  parse_response (Response, #parse_state {});
parse_response (Response, State = #parse_state { remaining = Remaining }) ->
  StateOut =
    case Remaining of
      undefined ->
        get_lines (Response, State);
      _ ->
        get_lines (Remaining ++ Response,
                   State#parse_state { remaining = undefined })
    end,
  { StateOut#parse_state.errors, StateOut#parse_state { errors = 0 } }.

get_lines (Lines, State = #parse_state { errors = CurrentErrors,
                                         expected = Expected }) ->
  case get_line (Lines) of
    {undefined, ""} ->
      State#parse_state { remaining = undefined };
    {undefined, Rest} ->
      State#parse_state { remaining = Rest };
    {Line, Rest} ->
      { Errors, Expecting } =
        case process_line (Line) of
          {error, Message} ->
            error_logger:error_msg ("~p",[Message]),
            { 1, 0 };
          {expecting, N} ->
            { N, N };
          ok ->
            { 0, 0 }
        end,
      ExpectedOut =
        case Expected =/= 0 of
          true ->
            case parse_status_message (Line) of
              {error, {line, Index, Timestamp}} ->
                % TODO: better handling of this error type
                error_logger:error_msg ("~p : ~p", [Index, Timestamp]);
%                case
%                  mondemand_backend_stats_rrd_recent:check (Index, Timestamp)
%                of
%                  error -> error_logger:error_msg ("Error 1 : ~p",[Line]);
%                  _ -> ok
%                end;
              _ ->
                error_logger:error_msg ("Error 2 :~p",[Line]),
                ok
            end,
            Expected - 1;
          false ->
            Expecting
        end,
      get_lines (Rest, State#parse_state { errors = CurrentErrors + Errors,
                                           expected = ExpectedOut })
  end.

get_line (Lines) ->
  get_line (Lines, []).

get_line ([], CurrentLine) ->
  { undefined, lists:reverse (CurrentLine) };
get_line ([$\n|Rest], CurrentLine) ->
  {lists:reverse (CurrentLine), Rest};
get_line ([Char|Remaining], CurrentLine) ->
  get_line (Remaining, [Char|CurrentLine]).

% From RRDCACHED manpage
% The daemon answers with a line consisting of a status code and a short
% status message, separated by one or more space characters. A negative
% status code signals an error, a positive status code or zero signal
% success. If the status code is greater than zero, it indicates the
% number of lines that follow the status line.
%
% Examples:
%
%   0 Success<LF>
%
%   2 Two lines follow<LF>
%   This is the first line<LF>
%   And this is the second line<LF>
%
process_line (Line) ->
  case parse_status_line (Line) of
    {status, N, StatusMessage} when N < 0 ->
      {error, parse_status_message (StatusMessage)};
    {status, N, errors} when N > 0 ->
      {expecting, N};
    _ ->
      ok
  end.

parse_status_line (Status) ->
  case string:to_integer (Status) of
    {error, E} -> {error, {parse_status_line, E}};
    % string:to_integer/1 returns {integer, Rest}, we then strip
    % a SPACE (decimal value of 32), and check to see if there were errors
    {N, [32|R]} ->
      case R of
        "errors" -> {status, N, errors};
        _ -> {status, N, R}
      end
  end.

parse_status_message ("No such file: " ++ File) ->
  {error, {no_file, File}};
% Also from RRDCACHED manpage
%
% Command processing is finished when the client sends a dot (".") on
% its own line.  After the client has finished, the server responds
% with an error count and the list of error messages (if any).  Each
% error messages indicates the number of the command to which it
% corresponds, and the error message itself.  The first user command
% after BATCH is command number one.
%
% client:  BATCH
% server:  0 Go ahead.  End with dot '.' on its own line.
% client:  UPDATE x.rrd 1223661439:1:2:3            <--- command #1
% client:  UPDATE y.rrd 1223661440:3:4:5            <--- command #2
% client:  and so on...
% client:  .
% server:  2 Errors
% server:  1 message for command 1
% server:  12 message for command 12
parse_status_message (Line) ->
  case string:to_integer (Line) of
    {error, _} -> {error, Line};
    % match " illegal attempt to update using time Timestamp "
    {N, [$\s,$i,$l,$l,$e,$g,$a,$l,$\s,$a,$t,$t,$e,$m,$p,$t,$\s,$t,$o,$\s,$u,$p,$d,$a,$t,$e,$\s,$u,$s,$i,$n,$g,$\s,$t,$i,$m,$e,$\s|TR]} ->
      case string:to_float (TR) of
        {error, _} -> {error, Line};
        {T, _} -> {error, {line, N, trunc(T)}}
      end;
    % match " No such file: "
    {_, [$\s,$N,$o,$\s,$s,$u,$c,$h,$\s,$f,$i,$l,$e,$:,$\s|File]} ->
      {error, {no_file, File}};
    % catches anything else
    {N, Unknown} ->
      error_logger:info_msg ("parse_status_message(~p) unrecognized",[Line]),
      {error, {unknown, N, Unknown}}
  end.
