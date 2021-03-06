require 'app/libraries'

module Hurl
  class App < Sinatra::Base
    register Mustache::Sinatra
    register Sinatra::BasicAuth
    helpers Hurl::Helpers

    dir = File.dirname(File.expand_path(__FILE__))

    set :root,     File.dirname(dir)
    set :app_file, __FILE__

    set :views, "#{dir}/templates"

    set :mustache, {
      :namespace => Object,
      :views     => "#{dir}/views",
      :templates => "#{dir}/templates"
    }

    enable :sessions

    def initialize(*args)
      super
      @debug = ENV['DEBUG']
    end

    authorize do |username, password|
      username == ENV['BASIC_AUTH_USERNAME'] && password == ENV['BASIC_AUTH_PASSWORD']
    end

    #
    # routes
    #

    before do
      @user = User.new
      @flash = session.delete('flash')
    end

    get '/' do
      @hurls = @user.hurls
      mustache :hurls
    end
    
    protect do
      get '/hurls/new/?' do
        @hurl = params
        mustache :hurl_form
      end
    end

    get '/hurls/:id/?' do
      @hurl = find_hurl(params[:id])
      @view = find_view(params[:id])
      @hurl ? mustache(:hurl_form) : not_found
    end
    
    protect do
      delete '/hurls/:id/?' do
        if @hurl = find_hurl(params[:id])
          @user.remove_hurl(@hurl['id'])
        end
        request.xhr? ? "ok" : redirect('/')
      end
    end

    get '/hurls/:id/:view_id/?' do
      @hurl = find_hurl(params[:id])
      @view = find_view(params[:view_id])
      @view_id = params[:view_id]
      @hurl && @view ? mustache(:hurl_form) : not_found
    end

    get '/views/:id/?' do
      @view = find_view(params[:id])
      @view ? mustache(:view, :layout => false) : not_found
    end

    get '/about/?' do
      mustache :about
    end

    get '/stats/?' do
      mustache :stats
    end

    protect do
      post '/' do
        return json(:error => "Calm down and try my margarita! (rate limited)") if rate_limited?

        url, method, auth = params.values_at(:url, :method, :auth)

        return json(:error => "That's... wait.. what?! (invalid URL)") if invalid_url?(url)

        curl = Curl::Easy.new(url)

        sent_headers = []
        curl.on_debug do |type, data|
          # track request headers
          sent_headers << data if type == Curl::CURLINFO_HEADER_OUT
        end

        curl.follow_location = true if params[:follow_redirects]

        # ensure a method is set
        method = (method.to_s.empty? ? 'GET' : method).upcase

        # update auth
        add_auth(auth, curl, params)

        # arbitrary headers
        add_headers_from_arrays(curl, params["header-keys"], params["header-vals"])

        # arbitrary post params
        if params['post-body'] && ['POST', 'PUT'].index(method)
          post_data = [params['post-body']]
        else
          post_data = make_fields(method, params["param-keys"], params["param-vals"])
        end

        begin
          debug { puts "#{method} #{url}" }

          if method == 'PUT'
            curl.http_put(stringify_data(post_data))
          else
            curl.send("http_#{method.downcase}", *post_data)
          end

          debug do
            puts sent_headers.join("\n")
            puts post_data.join('&') if post_data.any?
            puts curl.header_str
          end

          header  = pretty_print_headers(curl.header_str)
          type    = url =~ /(\.js)$/ ? 'js' : curl.content_type
          body    = pretty_print(type, curl.body_str)
          request = pretty_print_requests(sent_headers, post_data)

          hurl_id = save_hurl(params)
          json :header    => header,
               :body      => body,
               :request   => request,
               :hurl_id   => hurl_id,
               :prev_hurl => @user ? @user.second_to_last_hurl_id : nil,
               :view_id   => save_view(hurl_id, header, body, request)
        rescue => e
          json :error => CGI::escapeHTML(e.to_s)
        end
      end
    end


    #
    # error handlers
    #

    not_found do
      mustache :"404"
    end

    error do
      mustache :"500"
    end


    #
    # route helpers
    #

    # is this a url hurl can handle. basically a spam check.
    def invalid_url?(url)
      valid_schemes = ['http', 'https']
      begin
        uri = URI.parse(url)
        raise URI::InvalidURIError if uri.host == 'hurl.it'
        raise URI::InvalidURIError if !valid_schemes.include? uri.scheme
        false
      rescue URI::InvalidURIError
        true
      end
    end

    # update auth based on auth type
    def add_auth(auth, curl, params)
      if auth == 'basic'
        username, password = params.values_at(:username, :password)
        encoded = Base64.encode64("#{username}:#{password}").gsub("\n",'')
        curl.headers['Authorization'] = "Basic #{encoded}"
      end
    end

    # headers from non-empty keys and values
    def add_headers_from_arrays(curl, keys, values)
      keys, values = Array(keys), Array(values)

      keys.each_with_index do |key, i|
        next if values[i].to_s.empty?
        curl.headers[key] = values[i]
      end
    end

    # post params from non-empty keys and values
    def make_fields(method, keys, values)
      return [] unless %w( POST PUT ).include? method

      fields = []
      keys, values = Array(keys), Array(values)
      keys.each_with_index do |name, i|
        value = values[i]
        next if name.to_s.empty? || value.to_s.empty?
        fields << Curl::PostField.content(name, value)
      end
      fields
    end

    def save_view(id, header, body, request)
      hash = { 'header' => header, 'body' => body, 'request' => request }
      DB.save(:views, id, hash)
      id
    end

    def save_hurl(params)
      id = sha(params.to_s)
      DB.save(:hurls, id, params.merge(:id => id))
      @user.add_hurl(id) if @user
      id
    end

    def find_hurl(id)
      DB.find(:hurls, id)
    end

    def find_view(id)
      DB.find(:views, id)
    end

    def find_hurl_or_view(id)
       find_hurl(id) || find_view(id)
    end

    # has this person made too many requests?
    def rate_limited?
      false
    end

    # turn post_data into a string for PUT requests
    def stringify_data(data)
      if data.is_a? String
        data
      elsif data.is_a? Array
        data.map { |x| stringify_data(x) }.join("&")
      elsif data.is_a? Curl::PostField
        data.to_s
      else
        raise "Cannot stringify #{data.inspect}"
      end
    end
  end
end
