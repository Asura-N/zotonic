%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2009-2021 Marc Worrell
%% @doc Manage identities of users.  An identity can be an username/password, openid, oauth credentials etc.

%% Copyright 2009-2021 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(m_identity).
-author("Marc Worrell <marc@worrell.nl").

-behaviour(zotonic_model).

-export([
    m_get/3,

    is_user/2,
    get_username/1,
    get_username/2,
    delete_username/2,
    set_username/3,
    set_username_pw/4,
    set_expired/3,
    ensure_username_pw/2,
    check_username_pw/3,
    check_username_pw/4,
    hash/1,
    needs_rehash/1,
    hash_is_equal/2,
    get/2,
    get_rsc/2,
    get_rsc_by_type/3,
    get_rsc_by_type_keyprefix/4,
    get_rsc/3,

    is_email_verified/1,
    is_email_verified/2,

    is_valid_key/3,
    normalize_key/2,

    lookup_by_username/2,
    lookup_by_verify_key/2,
    lookup_by_type_and_key/3,
    lookup_by_type_and_key_multi/3,

    lookup_users_by_type_and_key/3,
    lookup_users_by_verified_type_and_key/3,

    set_by_type/4,
    set_by_type/5,
    delete_by_type/3,
    delete_by_type_and_key/4,
    delete_by_type_and_keyprefix/4,

    insert/4,
    insert/5,
    insert_single/4,
    insert_single/5,
    insert_unique/4,
    insert_unique/5,

    set_verify_key/2,
    set_verified/2,
    set_verified/4,
    is_verified/2,

    delete/2,
    merge/3,
    is_reserved_name/1,
    is_peer_allowed/1
]).

-export([
    generate_username/2
]).

-type password() :: iodata().
-type bcrypt_hash() :: {bcrypt, binary()}.
-type sha1_salted_hash() :: {hash, binary(), binary()}.
-type hash() :: bcrypt_hash() | sha1_salted_hash().

-type type() :: atom() | binary().
-type key() :: atom() | binary().

-export_type([
    type/0,
    key/0,
    password/0
    ]).

-include_lib("zotonic.hrl").

-define(IDN_CACHE_TIME, 3600*12).


%% @doc Fetch the value for the key from a model source
-spec m_get( list(), zotonic_model:opt_msg(), z:context()) -> zotonic_model:return().
m_get([ <<"lookup">>, Type, Key | Rest ], _Msg, Context) ->
    case z_acl:is_admin(Context) of
        true ->
            Idns = lookup_by_type_and_key_multi(Type, Key, Context),
            {ok, {Idns, Rest}};
        false ->
            {error, eacces}
    end;
m_get([ <<"generate_password">> | Rest ], _Msg, _Context) ->
    Password = iolist_to_binary([ z_ids:id(5), $-, z_ids:id(5), $-, z_ids:id(5) ]),
    {ok, {Password, Rest}};
m_get([ <<"is_email_verified">> | Rest ], _Msg, Context) ->
    {ok, {is_email_verified(Context), Rest}};
m_get([ Id, <<"is_user">> | Rest ], _Msg, Context) ->
    IsUser = case z_acl:rsc_visible(Id, Context) of
        true -> is_user(Id, Context);
        false -> undefined
    end,
    {ok, {IsUser, Rest}};
m_get([ Id, <<"username">> | Rest ], _Msg, Context) ->
    Username = case z_acl:rsc_editable(Id, Context) of
        true -> get_username(Id, Context);
        false -> undefined
    end,
    {ok, {Username, Rest}};
m_get([ Id, <<"all_types">> | Rest ], _Msg, Context) ->
    Idns = case z_acl:rsc_editable(Id, Context) of
        true -> get_rsc_types(Id, Context);
        false -> []
    end,
    {ok, {Idns, Rest}};
m_get([ Id, <<"all">> ], _Msg, Context) ->
    IdnRsc = case z_acl:rsc_editable(Id, Context) of
        true -> get_rsc(Id, Context);
        false -> []
    end,
    {ok, {IdnRsc, []}};
m_get([ Id, <<"all">>, Type | Rest ], _Msg, Context) ->
    IdnRsc = case z_acl:rsc_editable(Id, Context) of
        true -> get_rsc_by_type(Id, Type, Context);
        false -> []
    end,
    {ok, {IdnRsc, Rest}};
m_get([ <<"get">>, IdnId | Rest ], _Msg, Context) ->
    Idn1 = case get(IdnId, Context) of
        undefined -> undefined;
        Idn ->
            RscId = proplists:get_value(rsc_id, Idn),
            case z_acl:rsc_editable(RscId, Context) of
                true -> Idn;
                false -> undefined
            end
    end,
    {ok, {Idn1, Rest}};
m_get([ <<"verify">>, IdnId, VerifyKey | Rest ], _Msg, Context) ->
    Idn1 = case get(IdnId, Context) of
        Idn when is_list(Idn), is_binary(VerifyKey), VerifyKey =/= <<>> ->
            IdnVerifyKey = proplists:get_value(verify_key, Idn, <<>>),
            case is_equal(VerifyKey, IdnVerifyKey) of
                true -> Idn;
                false -> undefined
            end;
        _ ->
            undefined
    end,
    {ok, {Idn1, Rest}};
m_get([ Id, Type | Rest ], _Msg, Context) ->
    Idn = case z_acl:rsc_editable(Id, Context) of
        true -> get_rsc(Id, Type, Context);
        false -> undefined
    end,
    {ok, {Idn, Rest}};
m_get(Vs, _Msg, _Context) ->
    lager:error("Unknown ~p lookup: ~p", [?MODULE, Vs]),
    {error, unknown_path}.


%% @doc Check if the resource has any credentials that will make him/her an user
-spec is_user(m_rsc:resource(), z:context()) -> boolean().
is_user(Id, Context) ->
    case z_db:q1(
        "select count(*) from identity where rsc_id = $1 and type in ('username_pw', 'openid')",
        [m_rsc:rid(Id, Context)],
        Context
    ) of
        0 -> false;
        _ -> true
    end.

%% @doc Return the username of the current user
-spec get_username(z:context()) -> binary() | undefined.
get_username(Context) ->
    case z_acl:user(Context) of
        undefined -> undefined;
        UserId -> get_username(UserId, Context)
    end.

%% @doc Return the username of the resource id, undefined if no username
-spec get_username(m_rsc:resource(), z:context()) -> binary() | undefined.
get_username(RscId, Context) when is_integer(RscId) ->
    F = fun() ->
        z_db:q1(
            "select key from identity where rsc_id = $1 and type = 'username_pw'",
            [m_rsc:rid(RscId, Context)],
            Context)
    end,
    z_depcache:memo(F, {username, RscId}, 3600, [ {idn, RscId} ], Context).


%% @doc Check if the user is allowed to change the username of a resource.
-spec is_allowed_set_username( m_rsc:resource_id(), z:context() ) -> boolean().
is_allowed_set_username(Id, Context) when is_integer(Id) ->
    z_acl:is_admin(Context)
    orelse z_acl:is_allowed(use, mod_admin_identity, Context)
    orelse (z_acl:is_allowed(update, Id, Context) andalso Id =:= z_acl:user(Context)).


%% @doc Delete an username from a resource.
-spec delete_username(m_rsc:resource() | undefined, z:context()) -> ok | {error, eacces | enoent}.
delete_username(undefined, _Context) ->
    {error, enoent};
delete_username(1, Context) ->
    lager:warning("Trying to delete admin username (1) by ~p", [ z_acl:user(Context) ]),
    {error, eacces};
delete_username(RscId, Context) when is_integer(RscId) ->
    case is_allowed_set_username(RscId, Context)  of
        true ->
            z_db:q(
                "delete from identity where rsc_id = $1 and type = 'username_pw'",
                [RscId],
                Context
            ),
            flush(RscId, Context),
            z_mqtt:publish(
                [ <<"model">>, <<"identity">>, <<"event">>, RscId, <<"username_pw">> ],
                #{
                    id => RscId,
                    type => <<"username_pw">>
                },
                z_acl:sudo(Context)),
            ok;
        false ->
            {error, eacces}
    end;
delete_username(Id, Context) ->
    delete_username( m_rsc:rid(Id, Context), Context ).


%% @doc Mark the username_pw identity of an user as 'expired', this forces a prompt
%%      for a password reset on the next authentication.
set_expired(UserId, true, Context) ->
    case z_db:q("
        update identity
        set prop1 = 'expired'
        where type = 'username_pw'
          and rsc_id = $1",
        [ UserId ],
        Context)
    of
        0 -> {error, enoent};
        _ ->
            flush(UserId, Context),
            ok
    end;
set_expired(UserId, false, Context) ->
    case z_db:q("
        update identity
        set prop1 = 'expired'
        where type = ''
          and rsc_id = $1",
        [ UserId ],
        Context)
    of
        0 -> {error, enoent};
        _ ->
            flush(UserId, Context),
            ok
    end.

%% @doc Change the username of the resource id, only possible if there is
%% already an username/password set
-spec set_username( m_rsc:resource() | undefined, binary() | string(), z:context()) -> ok | {error, eacces | enoent | eexist}.
set_username(undefined, _Username, _Context) ->
    {error, enoent};
set_username(1, _Username, Context) ->
    lager:warning("Trying to set admin username (1) by ~p", [ z_acl:user(Context) ]),
    {error, eacces};
set_username(Id, Username, Context) when is_integer(Id) ->
    case is_allowed_set_username(Id, Context) of
        true ->
            Username1 = z_string:to_lower( z_convert:to_binary(Username) ),
            case is_reserved_name(Username1) of
                true ->
                    {error, eexist};
                false ->
                    F = fun(Ctx) ->
                        UniqueTest = z_db:q1("
                            select count(*)
                            from identity
                            where type = 'username_pw'
                              and rsc_id <> $1 and key = $2",
                            [Id, Username1],
                            Ctx
                        ),
                        case UniqueTest of
                            0 ->
                                case z_db:q("
                                        update identity
                                        set key = $2,
                                            modified = now()
                                        where rsc_id = $1
                                          and type = 'username_pw'",
                                        [Id, Username1],
                                        Ctx)
                                of
                                    1 -> ok;
                                    0 -> {error, enoent};
                                    {error, _} ->
                                        {error, eexist} % assume duplicate key error?
                                end;
                            _Other ->
                                {error, eexist}
                        end
                    end,
                    case z_db:transaction(F, Context) of
                        ok ->
                            flush(Id, Context),
                            z:info(
                                "Change of username for user ~p (~s)",
                                [ Id, Username1 ],
                                [ {module, ?MODULE} ],
                                Context),
                            z_mqtt:publish(
                                [ <<"model">>, <<"identity">>, <<"event">>, Id, <<"username_pw">> ],
                                #{
                                    id => Id,
                                    type => <<"username_pw">>
                                },
                                z_acl:sudo(Context)),
                            z_depcache:flush(Id, Context),
                            ok;
                        {rollback, {error, _} = Error, _Trace} ->
                            Error;
                        {error, _} = Error ->
                            Error
                    end
            end;
        false ->
            {error, eacces}
    end;
set_username(Id, Username, Context) ->
    set_username( m_rsc:rid(Id, Context), Username, Context ).


%% @doc Set the username/password of a resource.  Replaces any existing username/password.
-spec set_username_pw(m_rsc:resource() | undefined, binary()|string(), binary()|string(), z:context()) -> ok | {error, Reason :: term()}.
set_username_pw(undefined, _, _, _) ->
    {error, enoent};
set_username_pw(1, _, _, Context) ->
    lager:warning("Trying to set admin username (1) by ~p", [ z_acl:user(Context) ]),
    {error, eacces};
set_username_pw(Id, Username, Password, Context)  when is_integer(Id) ->
    case is_allowed_set_username(Id, Context) of
        true ->
            Username1 = z_string:trim(z_string:to_lower(Username)),
            IsForceDifferent = z_convert:to_bool( m_config:get_value(site, password_force_different, Context) ),
            set_username_pw_1(IsForceDifferent, m_rsc:rid(Id, Context), Username1, Password, Context);
        false ->
            {error, eacces}
    end;
set_username_pw(Id, Username, Password, Context) ->
    set_username_pw(m_rsc:rid(Id, Context), Username, Password, Context).

set_username_pw_1(true, Id, Username, Password, Context) ->
    case check_username_pw_1(Username, Password, Context) of
        {ok, _} ->
            {error, password_match};
        {error, E} when E =:= nouser; E =:= password ->
            set_username_pw_2(Id, Username, Password, Context);
        {error, _} = Error ->
            Error
    end;
set_username_pw_1(false, Id, Username, Password, Context) when is_integer(Id) ->
    set_username_pw_2(Id, Username, Password, Context).


set_username_pw_2(Id, Username, Password, Context) when is_integer(Id) ->
    Hash = hash(Password),
    case z_db:transaction(fun(Ctx) -> set_username_pw_trans(Id, Username, Hash, Ctx) end, Context) of
        {ok, S} ->
            case S of
                new ->
                    z:info(
                        "New username/password for user ~p (~s)",
                        [ Id, Username ],
                        [ {module, ?MODULE} ],
                        Context);
                exists ->
                    z:info(
                        "Change of username/password for user ~p (~s)",
                        [ Id, Username ],
                        [ {module, ?MODULE} ],
                        Context)
            end,
            reset_auth_tokens(Id, Context),
            flush(Id, Context),
            z_mqtt:publish(
                [ <<"model">>, <<"identity">>, <<"event">>, Id, <<"username_pw">> ],
                #{
                    id => Id,
                    type => <<"username_pw">>
                },
                z_acl:sudo(Context)),
            ok;
        {rollback, {{error, _} = Error, _Trace} = ErrTrace} ->
            lager:error("set_username_pw error for ~p, setting username. ~p: ~p",
                [Username, Error, ErrTrace]),
            Error;
        {error, _} = Error ->
            lager:error("set_username_pw error for ~p, setting username. ~p",
                        [Username, Error]),
            Error
    end.

set_username_pw_trans(Id, Username, Hash, Context) ->
    case z_db:q("
                update identity
                set key = $2,
                    propb = $3,
                    prop1 = '',
                    is_verified = true,
                    modified = now()
                where type = 'username_pw'
                  and rsc_id = $1",
        [Id, Username, ?DB_PROPS(Hash)],
        Context)
    of
        0 ->
            case is_reserved_name(Username) of
                true ->
                    {rollback, {error, eexist}};
                false ->
                    UniqueTest = z_db:q1(
                        "select count(*) from identity where type = 'username_pw' and key = $1",
                        [Username],
                        Context
                    ),
                    case UniqueTest of
                        0 ->
                            1 = z_db:q(
                                "insert into identity (rsc_id, is_unique, is_verified, type, key, propb)
                                values ($1, true, true, 'username_pw', $2, $3)",
                                [Id, Username, ?DB_PROPS(Hash)],
                                Context
                            ),
                            z_db:q(
                                "update rsc set creator_id = id where id = $1 and creator_id <> id",
                                [Id],
                                Context
                            ),
                            {ok, new};
                        _Other ->
                            {rollback, {error, eexist}}
                    end
            end;
        1 ->
             {ok, exists}
    end.

flush(Id, Context) ->
    z_depcache:flush(Id, Context),
    z_depcache:flush({idn, Id}, Context).

%% @doc Ensure that the user has an associated username and password
-spec ensure_username_pw(m_rsc:resource(), z:context()) -> ok | {error, term()}.
ensure_username_pw(1, _Context) ->
    {error, admin_password_cannot_be_set};
ensure_username_pw(Id, Context) ->
    case z_acl:is_allowed(use, mod_admin_identity, Context) orelse z_acl:user(Context) == Id of
        true ->
            RscId = m_rsc:rid(Id, Context),
            case z_db:q1(
                "select count(*) from identity where type = 'username_pw' and rsc_id = $1",
                [RscId],
                Context
            ) of
                0 ->
                    Username = generate_username(RscId, Context),
                    Password = binary_to_list(z_ids:id()),
                    set_username_pw(RscId, Username, Password, Context);
                _N ->
                    ok
            end;
        false ->
            {error, eacces}
    end.

generate_username(Id, Context) ->
    Username = base_username(Id, Context),
    username_unique(Username, Context).

username_unique(U, Context) ->
    case z_db:q1(
        "select count(*) from identity where type = 'username_pw' and key = $1",
        [U],
        Context
    ) of
        0 -> U;
        _ -> username_unique_x(U, 10, Context)
    end.

username_unique_x(U, X, Context) ->
    N = z_convert:to_binary(z_ids:number(X)),
    U1 = <<U/binary, $., N/binary>>,
    case z_db:q1(
        "select count(*) from identity where type = 'username_pw' and key = $1",
        [U1],
        Context
    ) of
        0 -> U1;
        _ -> username_unique_x(U, X * 10, Context)
    end.


base_username(Id, Context) ->
    T1 = iolist_to_binary([
        z_convert:to_binary(m_rsc:p_no_acl(Id, name_first, Context)),
        " ",
        z_convert:to_binary(m_rsc:p_no_acl(Id, name_surname, Context))
    ]),
    case nospace(z_string:trim(T1)) of
        <<>> ->
            case nospace(m_rsc:p_no_acl(Id, title, Context)) of
                <<>> -> z_ids:identifier(6);
                Title -> Title
            end;
        Name ->
            Name
    end.

nospace(undefined) ->
    <<>>;
nospace([]) ->
    <<>>;
nospace(<<>>) ->
    <<>>;
nospace(S) ->
    S1 = z_string:truncatechars(z_string:trim(S), 32, ""),
    S2 = z_string:to_slug(S1),
    nodash(binary:replace(S2, <<"-">>, <<".">>, [global])).

nodash(<<".">>) ->
    <<>>;
nodash(S) ->
    case binary:replace(S, <<"..">>, <<".">>, [global]) of
        S -> S;
        S1 -> nodash(S1)
    end.

%% @doc Return the rsc_id with the given username/password.
%%      If succesful then updates the 'visited' timestamp of the entry.
-spec check_username_pw(binary() | string(), binary() | string(), z:context()) ->
            {ok, m_rsc:resource_id()} | {error, term()}.
check_username_pw(Username, Password, Context) ->
    check_username_pw(Username, Password, [], Context).

%% @doc Return the rsc_id with the given username/password.
%%      If succesful then updates the 'visited' timestamp of the entry.
-spec check_username_pw(binary() | string(), binary() | string(), list() | map(), z:context()) ->
            {ok, m_rsc:resource_id()} | {error, term()}.
check_username_pw(Username, Password, QueryArgs, Context) when is_list(QueryArgs) ->
    check_username_pw(Username, Password, maps:from_list(QueryArgs), Context);
check_username_pw(Username, Password, QueryArgs, Context) when is_map(QueryArgs) ->
    NormalizedUsername = z_convert:to_binary( z_string:trim( z_string:to_lower(Username) ) ),
    case z_notifier:first(#auth_precheck{ username =  NormalizedUsername }, Context) of
        Ok when Ok =:= ok; Ok =:= undefined ->
            case post_check( check_username_pw_1(NormalizedUsername, Password, Context), QueryArgs, Context ) of
                {ok, RscId} ->
                    z_notifier:notify_sync(
                        #auth_checked{
                            id = RscId,
                            username = NormalizedUsername,
                            is_accepted = true
                        },
                        Context),
                    {ok, RscId};
                {error, {expired, RscId}} ->
                    z_notifier:notify_sync(
                        #auth_checked{
                            id = RscId,
                            username = NormalizedUsername,
                            is_accepted = true
                        },
                        Context),
                    {error, {expired, RscId}};
                {error, need_passcode} = Error ->
                    Error;
                Error ->
                    z_notifier:notify_sync(
                        #auth_checked{
                            id = undefined,
                            username = NormalizedUsername,
                            is_accepted = false
                        },
                        Context),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

post_check({ok, RscId}, QueryArgs, Context) ->
    case z_notifier:first(#auth_postcheck{ id = RscId, query_args = QueryArgs }, Context) of
        ok -> {ok, RscId};
        undefined -> {ok, RscId};
        Error -> Error
    end;
post_check(Error, _QueryArgs, _Context) ->
    Error.

check_username_pw_1(_Username, "", _Context) ->
    {error, password};
check_username_pw_1(_Username, <<>>, _Context) ->
    {error, password};
check_username_pw_1(<<"admin">>, Password, Context) ->
    Password1 = z_convert:to_binary(Password),
    case z_convert:to_binary( m_site:get(admin_password, Context) ) of
        <<"admin">> when Password1 =:= <<"admin">> ->
            % Only allow default password from allowed ip addresses
            case is_peer_allowed(Context) of
                true ->
                    z_db:q("update identity set visited = now() where id = 1", Context),
                    flush(1, Context),
                    {ok, 1};
                false ->
                    lager:error(
                        "admin login with default password from non allowed ip address ~p",
                        [m_req:get(peer, Context)]
                    ),
                    {error, peer_not_allowed}
            end;
        AdminPassword ->
            case is_equal(Password1, AdminPassword) of
                true ->
                    z_db:q("update identity set visited = now() where id = 1", Context),
                    flush(1, Context),
                    {ok, 1};
                false ->
                    {error, password}
            end
    end;
check_username_pw_1(Username, Password, Context) ->
    Username1 = z_convert:to_binary( z_string:trim(z_string:to_lower(Username)) ),
    Password1 = z_convert:to_binary( Password ),
    case z_notifier:first( #auth_validate{ username = Username1, password = Password1 }, Context) of
        {ok, _} = OK ->
            OK;
        {error, _} = Error ->
            Error;
        undefined ->
            Row = z_db:q_row("select rsc_id, propb, prop1 from identity where type = 'username_pw' and key = $1", [Username1], Context),
            case Row of
                undefined ->
                    % If the Username looks like an e-mail address, try by Email & Password
                    case z_email_utils:is_email(Username1) of
                        true -> check_email_pw(Username1, Password, Context);
                        false -> {error, nouser}
                    end;
                {RscId, Hash, <<"expired">>} ->
                    case check_hash(RscId, Username, Password, Hash, Context) of
                        {ok, UserId} ->
                            {error, {expired, UserId}};
                        {error, _} = Error ->
                            Error
                    end;
                {RscId, Hash, _Prop1} ->
                    check_hash(RscId, Username, Password, Hash, Context)
            end
    end.

%% @doc Check if the tcp/ip peer address is a allowed ip address
is_peer_allowed(Context) ->
    z_ip_address:ip_match(m_req:get(peer_ip, Context), ip_allowlist(Context)).

ip_allowlist(Context) ->
    SiteAllowlist = m_config:get_value(site, ip_allowlist, Context),
    case z_utils:is_empty(SiteAllowlist) of
        true -> z_config:get(ip_allowlist);
        false -> SiteAllowlist
    end.

%% @doc Check is the password belongs to an user with the given e-mail address.
%% Multiple users can have the same e-mail address, so multiple checks are needed.
%% If succesful then updates the 'visited' timestamp of the entry.
%% @spec check_email_pw(Email, Password, Context) -> {ok, Id} | {error, Reason}
check_email_pw(Email, Password, Context) ->
    case lookup_by_type_and_key_multi(<<"email">>, Email, Context) of
        [] -> {error, nouser};
        Users -> check_email_pw1(Users, Email, Password, Context)
    end.

check_email_pw1([], _Email, _Password, _Context) ->
    {error, password};
check_email_pw1([Idn | Rest], Email, Password, Context) ->
    UserId = proplists:get_value(rsc_id, Idn),
    Row = z_db:q_row(
        "select rsc_id, key, propb from identity where type = 'username_pw' and rsc_id = $1",
        [UserId],
        Context
    ),
    case Row of
        undefined ->
            check_email_pw1(Rest, Email, Password, Context);
        {RscId, Username, Hash} ->
            case check_hash(RscId, Username, Password, Hash, Context) of
                {ok, Id} -> {ok, Id};
                {error, password} ->
                    check_email_pw1(Rest, Email, Password, Context)
            end
    end.

%% @doc Reset the user's auth tokens - done on password reset.
%%      This invalidates all authentication cookies.
-spec reset_auth_tokens( m_rsc:resource_id(), z:context() )  -> ok.
reset_auth_tokens(UserId, Context) ->
    z_db:transaction(
        fun(Ctx) ->
            delete_by_type(UserId, auth_autologon_secret, Ctx),
            delete_by_type(UserId, auth_secret, Ctx),
            ok
        end,
        Context).


%% @doc Fetch a specific identity entry.
get(IdnId, Context) ->
    z_db:assoc_row("select * from identity where id = $1", [IdnId], Context).

%% @doc Fetch all credentials belonging to the user "id"
-spec get_rsc(m_rsc:resource(), z:context()) -> list().
get_rsc(Id, Context) ->
    z_db:assoc("select * from identity where rsc_id = $1", [m_rsc:rid(Id, Context)], Context).


%% @doc Fetch all different identity types of an user
-spec get_rsc_types(m_rsc:resource(), z:context()) -> [ binary() ].
get_rsc_types(Id, Context) ->
    Rs = z_db:q("select type from identity where rsc_id = $1", [m_rsc:rid(Id, Context)], Context),
    [R || {R} <- Rs].

%% @doc Fetch all credentials belonging to the user "id" and of a certain type
-spec get_rsc_by_type(m_rsc:resource(), type(), z:context()) -> list().
get_rsc_by_type(Id, email, Context) ->
    get_rsc_by_type(Id, <<"email">>, Context);
get_rsc_by_type(Id, <<"email">>, Context) ->
    Idns = get_rsc_by_type_1(Id, <<"email">>, Context),
    case normalize_key(<<"email">>, m_rsc:p_no_acl(Id, email_raw, Context)) of
        undefined ->
            Idns;
        Email ->
            IsMissing = is_valid_key(<<"email">>, Email, Context)
                andalso not lists:any(fun(Idn) ->
                    proplists:get_value(key, Idn) =:= Email
                end,
                    Idns),
            case IsMissing of
                true ->
                    insert(Id, <<"email">>, Email, Context),
                    get_rsc_by_type_1(Id, <<"email">>, Context);
                false ->
                    Idns
            end
    end;
get_rsc_by_type(Id, Type, Context) ->
    get_rsc_by_type_1(Id, Type, Context).

get_rsc_by_type_1(Id, Type, Context) ->
    z_db:assoc(
        "select * from identity where rsc_id = $1 and type = $2 order by is_verified desc, key asc",
        [m_rsc:rid(Id, Context), Type],
        Context
    ).

-spec get_rsc_by_type_keyprefix(m_rsc:resource_id(), type(), key(), z:context()) -> list().
get_rsc_by_type_keyprefix(Id, Type, KeyPrefix, Context) ->
    z_db:assoc(
        "select *
         from identity
         where rsc_id = $1
           and type = $2
           and key like $3 || ':%'
         order by is_verified desc, key asc",
        [m_rsc:rid(Id, Context), Type, KeyPrefix],
        Context).


-spec get_rsc(m_rsc:resource_id(), type(), z:context()) -> list() | undefined.
get_rsc(Id, Type, Context) when is_integer(Id), is_atom(Type) ->
    get_rsc(Id, z_convert:to_binary(Type), Context);
get_rsc(Id, Type, Context) when is_integer(Id), is_binary(Type) ->
    F = fun() ->
        get_rsc_1(Id, Type, Context)
    end,
    z_depcache:memo(F, {idn, Id, Type}, ?IDN_CACHE_TIME, [ {idn, Id} ], Context).

get_rsc_1(Id, Type, Context) ->
    z_db:assoc_row(
        "select * from identity where rsc_id = $1 and type = $2",
        [m_rsc:rid(Id, Context), Type],
        Context
    ).


%% @doc Check if the primary email address of the user is verified.
is_email_verified(Context) ->
    is_email_verified(z_acl:user(Context), Context).

is_email_verified(UserId, Context) ->
    case m_rsc:p_no_acl(UserId, email_raw, Context) of
        undefined -> false;
        <<>> -> false;
        Email ->
            z_depcache:memo(
                fun() ->
                    E = normalize_key(<<"email">>, Email),
                    z_convert:to_bool(
                        z_db:q1("
                            select is_verified
                            from identity
                            where rsc_id = $1
                              and type = $2
                              and key = $3",
                           [UserId, <<"email">>, E],
                           Context) )
                end,
                {emaiL_verified, UserId},
                3600,
                [ UserId ],
                Context)
    end.

%% @doc Hash a password, using bcrypt
-spec hash(password()) -> bcrypt_hash().
hash(Pw) ->
    {bcrypt, erlpass:hash(Pw)}.

%% @doc Compare if a password is the same as a hash.
-spec hash_is_equal(password(), hash()) -> boolean().
hash_is_equal(Pw, {bcrypt, Hash}) ->
    erlpass:match(Pw, Hash);
hash_is_equal(Pw, {hash, Salt, Hash}) ->
    NewHash = crypto:hash(sha, [Salt, Pw]),
    is_equal(Hash, NewHash);
hash_is_equal(_, _) ->
    false.


%% @doc Check if the password hash needs to be rehashed.
-spec needs_rehash(hash()) -> boolean().
needs_rehash({bcrypt, _}) ->
    false;
needs_rehash({hash, _, _}) ->
    true.


-spec insert_single(m_rsc:resource(), type(), key(), z:context()) ->
    {ok, pos_integer()} | {error, invalid_key}.
insert_single(Rsc, Type, Key, Context) ->
    insert_single(Rsc, Type, Key, [], Context).

insert_single(Rsc, Type, Key, Props, Context) ->
    RscId = m_rsc:rid(Rsc, Context),
    case insert(RscId, Type, Key, Props, Context) of
        {ok, IdnId} ->
            z_db:q("
                delete from identity
                where rsc_id = $1
                  and type = $2
                  and id <> $3",
                [ RscId, Type, IdnId ],
                Context),
            flush(RscId, Context),
            {ok, IdnId};
        {error, _} = Error ->
            Error
    end.

%% @doc Create an identity record.
-spec insert(m_rsc:resource(), type(), key(), z:context()) ->
    {ok, pos_integer()} | {error, invalid_key}.
insert(Rsc, Type, Key, Context) ->
    insert(Rsc, Type, Key, [], Context).

insert(Rsc, Type, Key, Props, Context) ->
    KeyNorm = normalize_key(Type, Key),
    case is_valid_key(Type, KeyNorm, Context) of
        true -> insert_1(Rsc, Type, KeyNorm, Props, Context);
        false -> {error, invalid_key}
    end.

insert_1(Rsc, Type, Key, Props, Context) ->
    RscId = m_rsc:rid(Rsc, Context),
    case z_db:q1("select id
                  from identity
                  where rsc_id = $1
                    and type = $2
                    and key = $3",
        [RscId, Type, Key],
        Context)
    of
        undefined ->
            Props1 = [{rsc_id, RscId}, {type, Type}, {key, Key} | Props],
            Result = z_db:insert(identity, Props1, Context),
            flush(RscId, Context),
            z_mqtt:publish(
                [ <<"model">>, <<"identity">>, <<"event">>, RscId, z_convert:to_binary(Type) ],
                #{
                    id => RscId,
                    type => Type
                },
                z_acl:sudo(Context)),
            Result;
        IdnId ->
            case proplists:get_value(is_verified, Props, false) of
                true ->
                    set_verified_trans(RscId, Type, Key, Context),
                    flush(RscId, Context),
                    z_mqtt:publish(
                        [ <<"model">>, <<"identity">>, <<"event">>, RscId, z_convert:to_binary(Type) ],
                        #{
                            id => RscId,
                            type => Type
                        },
                        z_acl:sudo(Context));
                false ->
                    nop
            end,
            {ok, IdnId}
    end.

-spec is_valid_key( type(),  undefined | key(), z:context() ) -> boolean().
is_valid_key(_Type, undefined, _Context) -> false;
is_valid_key(email, Key, _Context) -> z_email_utils:is_email(Key);
is_valid_key(username_pw, Key, _Context) -> not is_reserved_name(Key);
is_valid_key(<<"email">>, Key, Context) -> is_valid_key(email, Key, Context);
is_valid_key(<<"username_pw">>, Key, Context) -> is_valid_key(username_pw, Key, Context);
is_valid_key(Type, _Key, _Context) when is_atom(Type); is_binary(Type) -> true.

-spec normalize_key(type(), key() | undefined) -> key() | undefined.
normalize_key(_Type, undefined) -> undefined;
normalize_key(username_pw, Key) -> z_convert:to_binary(z_string:trim(z_string:to_lower(Key)));
normalize_key(email, Key) -> z_convert:to_binary(z_string:trim(z_string:to_lower(Key)));
normalize_key("username_pw", Key) -> normalize_key(username_pw, Key);
normalize_key("email", Key) -> normalize_key(email, Key);
normalize_key(<<"username_pw">>, Key) -> normalize_key(username_pw, Key);
normalize_key(<<"email">>, Key) -> normalize_key(email, Key);
normalize_key(_Type, Key) -> Key.


%% @doc Create an unique identity record.
insert_unique(RscId, Type, Key, Context) ->
    insert(RscId, Type, Key, [{is_unique, true}], Context).
insert_unique(RscId, Type, Key, Props, Context) ->
    insert(RscId, Type, Key, [{is_unique, true} | Props], Context).


%% @doc Set the visited timestamp for the given user.
%% @todo Make this a log - so that we can see the last visits and check if this
%% is from a new browser/ip address.
-spec set_visited(m_rsc:resource_id(), z:context()) -> ok | {error, enoent}.
set_visited(undefined, _Context) ->
    ok;
set_visited(UserId, Context) when is_integer(UserId) ->
    case z_db:q(
        "update identity set visited = now() where rsc_id = $1 and type = 'username_pw'",
        [m_rsc:rid(UserId, Context)],
        Context)
    of
        0 ->
            {error, enoent};
        N when N >= 1 ->
            flush(UserId, Context),
            ok
    end.


%% @doc Set the verified flag on a record by identity id.
-spec set_verified(m_rsc:resource_id(), z:context()) -> ok | {error, notfound}.
set_verified(Id, Context) ->
    case z_db:q_row("select rsc_id, type from identity where id = $1", [Id], Context) of
        {RscId, Type} ->
            case z_db:q("
                    update identity
                    set is_verified = true,
                        verify_key = null,
                        modified = now()
                    where id = $1",
                    [Id],
                    Context)
            of
                1 ->
                    flush(RscId, Context),
                    z_mqtt:publish(
                        [ <<"model">>, <<"identity">>, <<"event">>, RscId, z_convert:to_binary(Type) ],
                        #{
                            id => RscId,
                            type => Type
                        },
                        z_acl:sudo(Context)),
                    ok;
                0 ->
                    {error, notfound}
            end;
        undefined ->
            {error, notfound}
    end.


%% @doc Set the verified flag on a record by rescource id, identity type and
%% value (eg an user's email address).
-spec set_verified( m_rsc:resource_id(), type(), key(), z:context()) -> ok | {error, badarg}.
set_verified(RscId, Type, Key, Context)
    when is_integer(RscId),
         Type =/= undefined,
         Key =/= undefined, Key =/= <<>>, Key =/= "" ->
    KeyNorm = normalize_key(Type, Key),
    Result = z_db:transaction(fun(Ctx) -> set_verified_trans(RscId, Type, KeyNorm, Ctx) end, Context),
    flush(RscId, Context),
    z_mqtt:publish(
        [ <<"model">>, <<"identity">>, <<"event">>, RscId, z_convert:to_binary(Type) ],
        #{
            id => RscId,
            type => Type
        },
        z_acl:sudo(Context)),
    Result;
set_verified(_RscId, _Type, _Key, _Context) ->
    {error, badarg}.

set_verified_trans(RscId, Type, Key, Context) ->
    case z_db:q("update identity
                 set is_verified = true,
                     verify_key = null,
                     modified = now()
                 where rsc_id = $1
                   and type = $2
                   and key = $3",
                [RscId, Type, Key],
                Context)
    of
        0 ->
            1 = z_db:q("insert into identity (rsc_id, type, key, is_verified)
                        values ($1,$2,$3,true)",
                       [RscId, Type, Key],
                       Context),
            ok;
        N when N > 0 ->
            ok
    end.

%% @doc Check if there is a verified identity for the user, beyond the username_pw
-spec is_verified( m_rsc:resource_id(), z:context() ) -> boolean().
is_verified(RscId, Context) ->
    case z_db:q1("select id from identity where rsc_id = $1 and is_verified = true and type <> 'username_pw'",
                [RscId], Context) of
        undefined -> false;
        _ -> true
    end.

-spec set_by_type(m_rsc:resource_id(), type(), key(), z:context()) -> ok.
set_by_type(RscId, Type, Key, Context) ->
    set_by_type(RscId, Type, Key, [], Context).

-spec set_by_type(m_rsc:resource_id(), type(), key(), term(), z:context()) -> ok.
set_by_type(RscId, Type, Key, Props, Context) ->
    F = fun(Ctx) ->
        case z_db:q("
                update identity
                set key = $3,
                    propb = $4,
                    modified = now()
                where rsc_id = $1
                  and type = $2",
                [ m_rsc:rid(RscId, Context), Type, Key, ?DB_PROPS(Props) ],
                Ctx)
        of
            0 ->
                z_db:q("insert into identity (rsc_id, type, key, propb) values ($1,$2,$3,$4)",
                       [ m_rsc:rid(RscId, Context), Type, Key, ?DB_PROPS(Props) ],
                       Ctx),
                ok;
            N when N > 0 ->
                ok
        end
    end,
    z_db:transaction(F, Context).

delete(IdnId, Context) ->
    case z_db:q_row("select rsc_id, type, key from identity where id = $1", [IdnId], Context) of
        undefined ->
            {ok, 0};
        {RscId, Type, Key} ->
            case z_acl:rsc_editable(RscId, Context) of
                true ->
                    case z_db:delete(identity, IdnId, Context) of
                        {ok, 1} ->
                            z_depcache:flush({idn, RscId}, Context),
                            z_mqtt:publish(
                                [ <<"model">>, <<"identity">>, <<"event">>, RscId, z_convert:to_binary(Type) ],
                                #{
                                    id => RscId,
                                    type => Type
                                },
                                z_acl:sudo(Context)),
                            maybe_reset_email_property(RscId, Type, Key, Context),
                            {ok, 1};
                        Other ->
                            Other
                    end;
                false ->
                    {error, eacces}
            end
    end.

%% @doc Move the identities of two resources, the identities are removed from the source id.
-spec merge(m_rsc:resource(), m_rsc:resource(), z:context()) -> ok | {error, term()}.
merge(WinnerId, LoserId, Context) ->
    case z_acl:rsc_editable(WinnerId, Context) andalso z_acl:rsc_editable(LoserId, Context) of
        true ->
            F = fun(Ctx) ->
                % Move all identities to the winner, except for duplicate type+key combinations
                LoserIdns = z_db:q("select type, key, id from identity where rsc_id = $1",
                    [m_rsc:rid(LoserId, Context)], Ctx),
                WinIdns = z_db:q("select type, key from identity where rsc_id = $1",
                    [m_rsc:rid(WinnerId, Context)], Ctx),
                AddIdns = lists:filter(
                    fun({Type, Key, _Id}) ->
                        case is_unique_identity_type(Type) of
                            true ->
                                not proplists:is_defined(Type, WinIdns);
                            false ->
                                not lists:member({Type, Key}, WinIdns)
                        end
                    end,
                    LoserIdns),
                lists:foreach(
                    fun({_Type, _Key, Id}) ->
                        z_db:q("update identity set rsc_id = $1 where id = $2",
                            [m_rsc:rid(WinnerId, Context), Id],
                            Ctx)
                    end,
                    AddIdns),
                case proplists:is_defined(<<"username_pw">>, AddIdns) of
                    true ->
                        z_db:q("update rsc set creator_id = id where id = $1 and creator_id <> id",
                            [m_rsc:rid(WinnerId, Context)], Context);
                    false ->
                        ok
                end
            end,
            z_db:transaction(F, Context),
            z_depcache:flush({idn, LoserId}, Context),
            z_depcache:flush({idn, WinnerId}, Context),
            z_mqtt:publish(
                [ <<"model">>, <<"identity">>, <<"event">>, LoserId ],
                #{
                    id => LoserId,
                    type => all
                },
                z_acl:sudo(Context)),
            z_mqtt:publish(
                [ <<"model">>, <<"identity">>, <<"event">>, WinnerId ],
                #{
                    id => WinnerId,
                    type => all
                },
                z_acl:sudo(Context)),
            ok;
        false ->
            {error, eacces}
    end.

is_unique_identity_type(<<"username_pw">>) -> true;
is_unique_identity_type(_) -> false.


%% @doc If an email identity is deleted, then ensure that the 'email' property is reset accordingly.
maybe_reset_email_property(Id, <<"email">>, Email, Context) when is_binary(Email) ->
    case normalize_key(<<"email">>, m_rsc:p_no_acl(Id, email_raw, Context)) of
        Email ->
            NewEmail = z_db:q1("
                    select key
                    from identity
                    where rsc_id = $1
                      and type = 'email'
                    order by is_verified desc, modified desc",
                [Id],
                Context),
            Context1 = z_context:set(is_m_identity_update, true, Context),
            {ok, _} = m_rsc:update(Id, [{email, NewEmail}], Context1),
            ok;
        _ ->
            ok
    end;
maybe_reset_email_property(_Id, _Type, _Key, _Context) ->
    ok.


-spec delete_by_type(m_rsc:resource(), type(), z:context()) -> ok.
delete_by_type(Rsc, Type, Context) ->
    RscId = m_rsc:rid(Rsc, Context),
    case z_db:q("delete from identity where rsc_id = $1 and type = $2", [RscId, Type], Context) of
        0 -> ok;
        _N ->
            z_depcache:flush({idn, RscId}, Context),
            z_mqtt:publish(
                [ <<"model">>, <<"identity">>, <<"event">>, RscId, z_convert:to_binary(Type) ],
                #{
                    id => RscId,
                    type => Type
                },
                z_acl:sudo(Context)),
            ok
    end.

-spec delete_by_type_and_key(m_rsc:resource(), type(), key(), z:context()) -> ok.
delete_by_type_and_key(Rsc, Type, Key, Context) ->
    RscId = m_rsc:rid(Rsc, Context),
    case z_db:q("delete from identity where rsc_id = $1 and type = $2 and key = $3",
                [RscId, Type, Key], Context)
    of
        0 -> ok;
        _N ->
            z_depcache:flush({idn, RscId}, Context),
            z_mqtt:publish(
                [ <<"model">>, <<"identity">>, <<"event">>, RscId, z_convert:to_binary(Type) ],
                #{
                    id => RscId,
                    type => Type
                },
                z_acl:sudo(Context)),
            ok
    end.

-spec delete_by_type_and_keyprefix(m_rsc:resource(), type(), key(), z:context()) -> ok.
delete_by_type_and_keyprefix(Rsc, Type, Key, Context) ->
    RscId = m_rsc:rid(Rsc, Context),
    case z_db:q("delete from identity where rsc_id = $1 and type = $2 and key like $3 || ':%'",
                [RscId, Type, Key], Context)
    of
        0 -> ok;
        _N ->
            z_depcache:flush({idn, RscId}, Context),
            z_mqtt:publish(
                [ <<"model">>, <<"identity">>, <<"event">>, RscId, z_convert:to_binary(Type) ],
                #{
                    id => RscId,
                    type => Type
                },
                z_acl:sudo(Context)),
            ok
    end.

lookup_by_username(Key, Context) ->
    lookup_by_type_and_key(username_pw, z_string:to_lower(Key), Context).

lookup_by_type_and_key(Type, Key, Context) ->
    Key1 = normalize_key(Type, Key),
    z_db:assoc_row("select * from identity where type = $1 and key = $2", [Type, Key1], Context).

lookup_by_type_and_key_multi(Type, Key, Context) ->
    Key1 = normalize_key(Type, Key),
    z_db:assoc("select * from identity where type = $1 and key = $2", [Type, Key1], Context).

lookup_users_by_type_and_key(Type, Key, Context) ->
    Key1 = normalize_key(Type, Key),
    z_db:assoc(
        "select usr.*
         from identity tp, identity usr
         where tp.rsc_id = usr.rsc_id
           and usr.type = 'username_pw'
           and tp.type = $1
           and tp.key = $2",
        [Type, Key1],
        Context).

lookup_users_by_verified_type_and_key(Type, Key, Context) ->
    Key1 = normalize_key(Type, Key),
    z_db:assoc(
        "select usr.*
         from identity tp, identity usr
         where tp.rsc_id = usr.rsc_id
           and usr.type = 'username_pw'
           and tp.type = $1
           and tp.key = $2
           and tp.is_verified",
        [Type, Key1],
        Context).

lookup_by_verify_key(Key, Context) ->
    z_db:assoc_row("select * from identity where verify_key = $1", [Key], Context).

set_verify_key(Id, Context) ->
    N = binary_to_list(z_ids:id(10)),
    case lookup_by_verify_key(N, Context) of
        undefined ->
            z_db:q("update identity
                    set verify_key = $2,
                        modified = now()
                    where id = $1",
                    [Id, N],
                    Context),
            {ok, N};
        _ ->
            set_verify_key(Id, Context)
    end.


check_hash(RscId, Username, Password, Hash, Context) ->
    N = #identity_password_match{
        rsc_id = RscId,
        password = Password,
        hash = Hash
    },
    case z_notifier:first(N, Context) of
        {ok, rehash} ->
            %% OK but module says it needs rehashing; do that using
            %% the current hashing mechanism
            ok = set_username_pw(RscId, Username, Password, z_acl:sudo(Context)),
            check_hash_ok(RscId, Context);
        ok ->
            check_hash_ok(RscId, Context);
        {error, Reason} ->
            {error, Reason};
        undefined ->
            {error, nouser}
    end.


check_hash_ok(RscId, Context) ->
    set_visited(RscId, Context),
    {ok, RscId}.

%% @doc Prevent insert of reserved usernames.
%% See: http://tools.ietf.org/html/rfc2142
%% See: https://arstechnica.com/security/2015/03/bogus-ssl-certificate
is_reserved_name(List) when is_list(List) ->
    is_reserved_name(z_convert:to_binary(List));
is_reserved_name(Name) when is_binary(Name) ->
    is_reserved_name_1(z_string:trim(z_string:to_lower(Name))).

is_reserved_name_1(<<>>) -> true;
is_reserved_name_1(<<"admin">>) -> true;
is_reserved_name_1(<<"administrator">>) -> true;
is_reserved_name_1(<<"postmaster">>) -> true;
is_reserved_name_1(<<"hostmaster">>) -> true;
is_reserved_name_1(<<"webmaster">>) -> true;
is_reserved_name_1(<<"abuse">>) -> true;
is_reserved_name_1(<<"security">>) -> true;
is_reserved_name_1(<<"root">>) -> true;
is_reserved_name_1(<<"www">>) -> true;
is_reserved_name_1(<<"uucp">>) -> true;
is_reserved_name_1(<<"ftp">>) -> true;
is_reserved_name_1(<<"usenet">>) -> true;
is_reserved_name_1(<<"news">>) -> true;
is_reserved_name_1(<<"wwwadmin">>) -> true;
is_reserved_name_1(<<"webadmin">>) -> true;
is_reserved_name_1(<<"mail">>) -> true;
is_reserved_name_1(_) -> false.


% Constant time comparison.
-spec is_equal(Extern :: binary(), Secret :: binary() ) -> boolean().
is_equal(A, B) -> is_equal(A, B, true).

is_equal(<<>>, <<>>, Eq) -> Eq;
is_equal(<<>>, _B, _Eq) -> false;
is_equal(<<_, A/binary>>, <<>>, _Eq) -> is_equal(A, <<>>, false);
is_equal(<<C, A/binary>>, <<C, B/binary>>, Eq) -> is_equal(A, B, Eq);
is_equal(<<_, A/binary>>, <<_, B/binary>>, _Eq) -> is_equal(A, B, false).
