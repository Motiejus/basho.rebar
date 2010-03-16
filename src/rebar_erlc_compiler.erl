%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009, 2010 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_erlc_compiler).

-export([compile/2,
         clean/2]).

-export([doterl_compile/2,
         doterl_compile/3]).

-include("rebar.hrl").

%% ===================================================================
%% Public API
%% ===================================================================

-spec compile(Config::#config{}, AppFile::string()) -> 'ok'.
compile(Config, _AppFile) ->
    doterl_compile(Config, "ebin"),
    rebar_base_compiler:run(Config, rebar_config:get_list(Config, mib_first_files, []),
                            "mibs", ".mib", "priv/mibs", ".bin",
                            fun compile_mib/3).

-spec clean(Config::#config{}, AppFile::string()) -> 'ok'.
clean(_Config, _AppFile) ->
    %% TODO: This would be more portable if it used Erlang to traverse
    %%       the dir structure and delete each file; however it would also
    %%       much slower.
    ok = rebar_file_utils:rm_rf("ebin/*.beam priv/mibs/*.bin"),

    %% Erlang compilation is recursive, so it's possible that we have a nested
    %% directory structure in ebin with .beam files within. As such, we want
    %% to scan whatever is left in the ebin/ directory for sub-dirs which
    %% satisfy our criteria.
    BeamFiles = rebar_utils:find_files("ebin", "^.*\\.beam\$"),
    rebar_file_utils:delete_each(BeamFiles),
    lists:foreach(fun(Dir) -> delete_dir(Dir, dirs(Dir)) end, dirs("ebin")),
    ok.


%% ===================================================================
%% .erl Compilation API (externally used by only eunit)
%% ===================================================================

-spec doterl_compile(Config::#config{}, OutDir::string()) -> 'ok'.
doterl_compile(Config, OutDir) ->
    doterl_compile(Config, OutDir, []).

doterl_compile(Config, OutDir, MoreSources) ->
    FirstErls = rebar_config:get_list(Config, erl_first_files, []),
    ErlOpts = rebar_config:get(Config, erl_opts, []),
    %% Support the src_dirs option allowing multiple directories to
    %% contain erlang source. This might be used, for example, should eunit tests be
    %% separated from the core application source.
    SrcDirs = src_dirs(proplists:append_values(src_dirs, ErlOpts)),
    RestErls  = [Source || Source <- gather_src(SrcDirs, []) ++ MoreSources,
                           lists:member(Source, FirstErls) == false],

    % Sort RestErls so that parse_transforms and behaviours are first
    % This should probably be somewhat combined with inspect_epp
    SortedRestErls = [K || {K, _V} <- lists:keysort(2,
        [{F, compile_priority(F)} || F <- RestErls ])],


    %% Make sure that ebin/ is on the path
    CurrPath = code:get_path(),
    code:add_path("ebin"),
    rebar_base_compiler:run(Config, FirstErls, SortedRestErls,
                            fun(S, C) -> internal_erl_compile(S, C, OutDir) end),
    code:set_path(CurrPath),
    ok.


%% ===================================================================
%% Internal functions
%% ===================================================================

-spec include_path(Source::string(), Config::#config{}) -> [string()].
include_path(Source, Config) ->
    ErlOpts = rebar_config:get(Config, erl_opts, []),
    ["include", filename:dirname(Source)] ++ proplists:get_all_values(i, ErlOpts).

-spec inspect(Source::string(), IncludePath::[string()]) -> {string(), [string()]}.
inspect(Source, IncludePath) ->
    ModuleDefault = filename:basename(Source, ".erl"),
    case epp:open(Source, IncludePath) of
        {ok, Epp} ->
            inspect_epp(Epp, Source, ModuleDefault, []);
        {error, Reason} ->
            ?DEBUG("Failed to inspect ~s: ~p\n", [Source, Reason]),
            {ModuleDefault, []}
    end.

-spec inspect_epp(Epp::pid(), Source::string(), Module::string(), Includes::[string()]) -> {string(), [string()]}.
inspect_epp(Epp, Source, Module, Includes) ->
    case epp:parse_erl_form(Epp) of
        {ok, {attribute, _, module, ModInfo}} ->
            case ModInfo of
                %% Typical module name, single atom
                ActualModule when is_atom(ActualModule) ->
                    ActualModuleStr = atom_to_list(ActualModule);
                %% Packag-ized module name, list of atoms
                ActualModule when is_list(ActualModule) ->
                    ActualModuleStr = string:join([atom_to_list(P) || P <- ActualModule], ".");
                %% Parameterized module name, single atom
                {ActualModule, _} when is_atom(ActualModule) ->
                    ActualModuleStr = atom_to_list(ActualModule);
                %% Parameterized and packagized module name, list of atoms
                {ActualModule, _} when is_list(ActualModule) ->
                    ActualModuleStr = string:join([atom_to_list(P) || P <- ActualModule], ".")
            end,
            inspect_epp(Epp, Source, ActualModuleStr, Includes);
        {ok, {attribute, 1, file, {Module, 1}}} ->
            inspect_epp(Epp, Source, Module, Includes);
        {ok, {attribute, 1, file, {Source, 1}}} ->
            inspect_epp(Epp, Source, Module, Includes);
        {ok, {attribute, 1, file, {IncFile, 1}}} ->
            inspect_epp(Epp, Source, Module, [IncFile | Includes]);
        {eof, _} ->
            epp:close(Epp),
            {Module, Includes};
        _ ->
            inspect_epp(Epp, Source, Module, Includes)
    end.

-spec needs_compile(Source::string(), Target::string(), Hrls::[string()]) -> boolean().
needs_compile(Source, Target, Hrls) ->
    TargetLastMod = filelib:last_modified(Target),
    lists:any(fun(I) -> TargetLastMod < filelib:last_modified(I) end,
              [Source] ++ Hrls).

-spec internal_erl_compile(Source::string(), Config::#config{}, Outdir::string()) -> 'ok' | 'skipped'.
internal_erl_compile(Source, Config, Outdir) ->
    %% Determine the target name and includes list by inspecting the source file
    {Module, Hrls} = inspect(Source, include_path(Source, Config)),

    %% Construct the target filename
    Target = filename:join([Outdir | string:tokens(Module, ".")]) ++ ".beam",
    ok = filelib:ensure_dir(Target),

    %% If the file needs compilation, based on last mod date of includes or
    %% the target,
    case needs_compile(Source, Target, Hrls) of
        true ->
            Opts = [{i, "include"}, {outdir, filename:dirname(Target)}, report, return] ++
                rebar_config:get(Config, erl_opts, []),
            case compile:file(Source, Opts) of
                {ok, _, []} ->
                    ok;
                {ok, _, _Warnings} ->
                    %% We got at least one warning -- if fail_on_warning is in options, fail
                    case lists:member(fail_on_warning, Opts) of
                        true ->
                            ?FAIL;
                        false ->
                            ok
                    end;
                _ ->
                    ?FAIL
            end;
        false ->
            skipped
    end.

-spec compile_mib(Source::string(), Target::string(), Config::#config{}) -> 'ok'.
compile_mib(Source, Target, Config) ->
    ok = rebar_utils:ensure_dir(Target),
    Opts = [{outdir, "priv/mibs"}, {i, ["priv/mibs"]}] ++
        rebar_config:get(Config, mib_opts, []),
    case snmpc:compile(Source, Opts) of
        {ok, _} ->
            ok;
        {error, compilation_failed} ->
            ?FAIL
    end.

gather_src([], Srcs) ->
    Srcs;
gather_src([Dir|Rest], Srcs) ->
    gather_src(Rest, Srcs ++ rebar_utils:find_files(Dir, ".*\\.erl\$")).

-spec src_dirs(SrcDirs::[string()]) -> [string()].
src_dirs([]) ->
    ["src"];
src_dirs(SrcDirs) ->
    SrcDirs ++ src_dirs([]).

-spec dirs(Dir::string()) -> [string()].
dirs(Dir) ->
    [F || F <- filelib:wildcard(filename:join([Dir, "*"])), filelib:is_dir(F)].

-spec delete_dir(Dir::string(), Subdirs::[string()]) -> 'ok' | {'error', atom()}.
delete_dir(Dir, []) ->
    file:del_dir(Dir);
delete_dir(Dir, Subdirs) ->
    lists:foreach(fun(D) -> delete_dir(D, dirs(D)) end, Subdirs),
    file:del_dir(Dir).

-spec compile_priority(File::string()) -> pos_integer().
compile_priority(File) ->
    case epp_dodger:parse_file(File) of
        {error, _} ->
            10; % couldn't parse the file, default priority
        {ok, Trees} ->
            F2 = fun({tree,arity_qualifier,_,
                        {arity_qualifier,{tree,atom,_,behaviour_info},
                            {tree,integer,_,1}}}, _) ->
                    2;
                ({tree,arity_qualifier,_,
                        {arity_qualifier,{tree,atom,_,parse_transform},
                            {tree,integer,_,2}}}, _) ->
                    1;
                (_, Acc) ->
                    Acc
            end,

            F = fun({tree, attribute, _, {attribute, {tree, atom, _, export},
                            [{tree, list, _, {list, List, none}}]}}, Acc) ->
                    lists:foldl(F2, Acc, List);
                (_, Acc) ->
                    Acc
            end,

            lists:foldl(F, 10, Trees)
    end.
