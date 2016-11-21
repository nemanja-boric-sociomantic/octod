/*******************************************************************************

    Implements persistent HTTP connection to GitHub API server which provides
    basic get/post/patch methods taking care of API details internally (like
    auth or multi-page responses).

    Copyright: Copyright (c) 2016 Sociomantic Labs. All rights reserved

    License: Boost Software License Version 1.0 (see LICENSE for details)

*******************************************************************************/

module octod.core;

import std.exception : enforce;

import vibe.http.client;
import vibe.data.json;
import vibe.core.log;

/**
    Configuration required to interact with GitHub API
 **/
struct Configuration
{
    /// URL prepended to all API requests
    string baseURL = "https://api.github.com";
    /// If present, will be used as auth username
    string username;
    /// If 'this.username' is present, will be used as auth password
    string password;
    /// If 'this.username' is empty, will be used as auth token
    string oauthToken;
    /// Sent as 'Accept' header
    string accept = "application/vnd.github.v3+json";
    /// By default client works in dry run mode
    bool dryRun = true;
}

/**
    Thrown upon any protocol/connection issues when trying to
    interact with API HTTP server.
 **/
class HTTPAPIException : Exception
{
    this ( string msg, string file = __FILE__, ulong line = __LINE__ )
    {
        super(msg, file, line);
    }
}

/**
    Wrapper on top of vibe.d `connectHTTP`, describing persistent HTTP
    connection to GitHub API server and providing convenience
    `get`/`post`/`patch` methods taking care of GitHub HTTP specifics.

    Does not implement any of higher level API interpretation, instead should
    be used as a core facilities for such util.

    Currently does not expose any of returned HTTP headers - it is not yet
    clear if this will be necessary for implementing more complex API
    methods.
 **/
struct HTTPConnection
{
    private
    {
        alias Connection = typeof(connectHTTP(null, 0, false));

        static assert (is(Connection == struct));
        Connection* connection;

        Configuration config;
    }

    /**
        Setups new connection instance and attempts connecting to the
        configured API server.

        Params:
            config = configuration used for interacting with API server

        Returns:
             instance of this struct connected to the API server and ready to
             start sending requests
     **/
    static HTTPConnection connect ( Configuration config )
    {
        auto conn = typeof(this)(config);
        conn.connect();
        return conn;
    }

    /**
        Constructor

        `connect` method must be called on constructed instance before
        it gets into usable state.

        Params:
            config = configuration used for interacting with API server
     **/
    this ( Configuration config )
    {
        import std.string : startsWith;

        if (!config.oauthToken.startsWith("bearer "))
            config.oauthToken = "bearer " ~ config.oauthToken;

        this.config = config;
    }

    /**
        Creates vibe.d persistent HTTP(S) connection to configured API
        server.

        Requires configured base URL to define explicit protocol (HTTP or HTTPS)
     **/
    void connect ( )
    {
        assert(this.connection is null);

        import std.regex;

        logInfo("Connecting to GitHub API server ...");

        static rgxURL = regex(r"^(\w*)://([^/]+)$");
        auto match = this.config.baseURL.matchFirst(rgxURL);

        enforce!HTTPAPIException(
            match.length == 3,
            "Malformed API base URL in configuration: " ~ this.config.baseURL
        );

        string addr = match[2];
        ushort port;
        bool   tls;

        switch (match[1])
        {
            case "http":
                port = 80;
                tls = false;
                break;
            case "https":
                port = 443;
                tls = true;
                break;
            default:
                throw new HTTPAPIException("Protocol not supported: " ~ match[1]);
        }

        this.connection = new Connection;
        *this.connection = connectHTTP(addr, port, tls);

        logInfo("Connected.");
    }

    /**
        Sends GET request to API server

        Params:
            url = GitHub API method URL (relative)

        Returns:
            Json body of the response. If response is multi-page, all pages
            are collected and concatenated into one returned json object.
     **/
    Json get ( string url )
    {
        assert (this.connection !is null);

        logInfo("GET %s", url);

        // initialize result as array - if actual response isn't array, it
        // will be overwritten by assignement anyway, otherwise it allows
        // easy concatenation of multi-page results

        Json result = Json.emptyArray;
        HTTPClientResponse response;

        url = this.config.baseURL ~ url;

        while (true)
        {
            response = this.connection.request(
                (scope request) {
                    request.requestURL = url;
                    request.method = HTTPMethod.GET;
                    this.prepareRequest(request);
                }
            );

            this.handleResponseStatus(response);

            auto json = response.readJson();
            if (json.type == Json.Type.Array)
            {
                foreach (element; json.get!(Json[]))
                    result.appendArrayElement(element);
            }
            else
                result = json;

            // GitHub splits long response lists into several "pages", each
            // needs to be retrieved by own request. If pages are present,
            // they are defined in "Link" header:

            import std.regex;

            static rgxLink = regex(`<([^>]+)>;\s+rel="next"`);

            if (auto link = "Link" in response.headers)
            {
                assert(result.type == Json.Type.Array);

                auto match = (*link).matchFirst(rgxLink);
                if (match.length == 2)
                    url = match[1];
                else
                    break;
            }
            else
                break;
        }

        return result;
    }

    /**
        Sends POST request to API server

        Params:
            url = GitHub API method URL (relative)
            json = request body to send

        Returns:
            Json body of the response.
     **/
    Json post ( string url, Json json )
    {
        assert (this.connection !is null);

        logInfo("POST %s", url);

        auto response = this.connection.request(
            (scope request) {
                request.requestURL = url;
                request.method = HTTPMethod.POST;
                this.prepareRequest(request);
                request.writeJsonBody(json);
            }
        );

        this.handleResponseStatus(response);

        return response.readJson();
    }

    /**
        Sends PATCH request to API server

        Params:
            url = GitHub API method URL (relative)
            json = request body to send

        Returns:
            Json body of the response.
     **/
    Json patch ( string url, Json json )
    {
        assert (this.connection !is null);

        logInfo("PATCH %s", url);

        auto response = this.connection.request(
            (scope request) {
                request.requestURL = url;
                request.method = HTTPMethod.PATCH;
                this.prepareRequest(request);
                request.writeJsonBody(json);
            }
        );

        this.handleResponseStatus(response);

        return response.readJson();
    }

    private void prepareRequest ( scope HTTPClientRequest request )
    {
        import vibe.http.auth.basic_auth : addBasicAuth;

        if (this.config.username.length > 0)
            request.addBasicAuth(this.config.username, this.config.password);
        else
            request.headers["Authorization"] = this.config.oauthToken;

        request.headers["Accept"] = this.config.accept;
    }

    private void handleResponseStatus ( scope HTTPClientResponse response )
    {
        import std.format;
        import vibe.http.status;

        auto status = response.statusCode;

        if (status == HTTPStatus.notFound)
            throw new HTTPAPIException("Requested non-existent API URL");

        enforce!HTTPAPIException(
            status >= 200 && status < 300,
            format("Expected status code 2xx, got %s", response.statusCode)
        );
    }
}