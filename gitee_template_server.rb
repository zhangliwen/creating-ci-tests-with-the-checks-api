require 'sinatra'
require 'dotenv/load' # Manages environment variables
require 'json'
require 'openssl'     # Verifies the webhook signature
require 'logger'      # Logs debug statements
require 'git'
require 'rest-client'
require 'pry'

set :port, 3000
set :bind, '0.0.0.0'

class GHAapp < Sinatra::Application
  GITEE_PERSONAL_ACCESS_TOKEN = ENV['GITEE_PERSONAL_ACCESS_TOKEN']
  configure :development do
    set :logging, Logger::DEBUG
  end

  before '/event_handler' do
    get_payload_request(request)
    verify_webhook_signature
    authenticate_app
  end

  post '/event_handler' do
    case request.env['HTTP_X_GITEE_EVENT']
    when 'Push Hook'
      create_check_run
    when 'Check Run Hook'
      case @payload['action']
      when 'created'
        initiate_check_run
      when 'rerequested'
        create_check_run
      when 'requested_action'
        take_requested_action
      end
    end

    200 # success status
  end

  helpers do
    def clone_repository(full_repo_name, repository, ref, repo_owner_username)
      @git = Git.clone("https://#{repo_owner_username}:#{@access_token}@14397.runjs.cn/#{full_repo_name}.git", repository)
      pwd = Dir.getwd
      Dir.chdir(repository)
      @git.pull
      @git.checkout(ref)
      Dir.chdir(pwd)
    end

    # Create a new check run with the status queued
    def create_check_run
      logger.debug "---- create check run status: liwen_rubocop"
      data = {
        details_url: 'https://gitee.com/liwen',
        name: 'liwen_rubocop',
        access_token: @access_token,
        head_sha: @payload['check_run'].nil? ? @payload['after'] : @payload['check_run']['head_sha']
      }
      repo = @payload['repository'].nil? ? @payload['project'] : @payload['repository']
      url = "https://14397.runjs.cn/api/v5/repos/#{repo['full_name']}/check-runs"
      RestClient.post url, data, {content_type: :json, accept: :json}
    end

    def initiate_check_run
      logger.debug "---- set check run status: in_progress"
      repo = @payload['repository'].nil? ? @payload['project'] : @payload['repository']
      url = "https://14397.runjs.cn/api/v5/repos/#{repo['full_name']}/check-runs/#{@payload['check_run']['id']}"
      data = {
        access_token: @access_token,
        status: 'in_progress'
      }
      RestClient.patch url, data, {content_type: :json, accept: :json}

      full_repo_name        = @payload['project']['full_name']
      repository            = @payload['project']['name']
      repo_owner_username   = @payload['project']['owner']['username']
      head_sha              = @payload['check_run']['head_sha']

      clone_repository(full_repo_name, repository, head_sha, repo_owner_username)

      @report = `rubocop '#{repository}' --format json`
      `rm -rf #{repository}`
      @output = JSON.parse @report

      annotations = []
      # You can create a maximum of 50 annotations per request to the Checks
      # API. To add more than 50 annotations, use the "Update a check run" API
      # endpoint. This example code limits the number of annotations to 50.
      # See /rest/reference/checks#update-a-check-run
      # for details.
      max_annotations = 50

      # RuboCop reports the number of errors found in "offense_count"
      if @output['summary']['offense_count'] == 0
        conclusion = 'success'
      else
        conclusion = 'success'
        # conclusion = 'failure'
        @output['files'].each do |file|
          # Only parse offenses for files in this app's repository
          file_path = file['path'].gsub(/#{repository}\//, '')
          annotation_level = 'notice'

          # Parse each offense to get details and location
          file['offenses'].each do |offense|
            # Limit the number of annotations to 50
            next if max_annotations == 0

            max_annotations -= 1

            start_line   = offense['location']['start_line']
            end_line     = offense['location']['last_line']
            start_column = offense['location']['start_column']
            end_column   = offense['location']['last_column']
            message      = offense['message']

            # Create a new annotation for each error
            annotation = {
              path: file_path,
              start_line: start_line,
              end_line: end_line,
              annotation_level: annotation_level,
              message: message
            }
            # Annotations only support start and end columns on the same line
            if start_line == end_line
              annotation.merge(start_column: start_column, end_column: end_column)
            end

            annotations.push(annotation)
          end
        end
      end

      # Updated check run summary and text parameters
      summary = "Octo RuboCop summary\n-Offense count: #{@output['summary']['offense_count']}\n-File count: #{@output['summary']['target_file_count']}\n-Target file count: #{@output['summary']['inspected_file_count']}"
      text = "Octo RuboCop version: #{@output['metadata']['rubocop_version']}"

      # Mark the check run as complete! And if there are warnings, share them.
      logger.debug "----     set check run status: completed"
      repo = @payload['repository'].nil? ? @payload['project'] : @payload['repository']
      url = "https://14397.runjs.cn/api/v5/repos/#{repo['full_name']}/check-runs/#{@payload['check_run']['id']}"
      data = {
        access_token: @access_token,
        conclusion: "failure",
        details_url: "https://gitee.com/liwen",
        output: {
          title: 'Octo RuboCop',
          summary: summary,
          text: text,
          annotations: annotations
        },
        actions: [
          {
            label: "Fix this",
            description: "Automatically fix all linter notices.",
            identifier: "fix_rubocop_notices"
          }
        ]
      }
      RestClient.patch url, data, {content_type: :json, accept: :json}
    end

    def take_requested_action
      full_repo_name        = @payload['project']['full_name']
      repository            = @payload['project']['name']
      repo_owner_username   = @payload['project']['owner']['username']
      head_branch           = @payload['check_run']['check_suite']['head_branch']

      if @payload['requested_action']['identifier'] == 'fix_rubocop_notices'
        clone_repository(full_repo_name, repository, head_branch, repo_owner_username)

        # Sets your commit username and email address
        @git.config('user.name', ENV['GITHUB_APP_USER_NAME'])
        @git.config('user.email', ENV['GITHUB_APP_USER_EMAIL'])

        # Automatically correct RuboCop style errors
        @report = `rubocop '#{repository}/*' --format json --auto-correct`

        pwd = Dir.getwd
        Dir.chdir(repository)
        begin
          @git.commit_all('Automatically fix Octo RuboCop notices.')
          @git.push("https://14397.runjs.cn/#{repo_owner_username}:#{@access_token}@github.com/#{full_repo_name}.git", head_branch)
        rescue StandardError
          # Nothing to commit!
          puts 'Nothing to commit'
        end
        Dir.chdir(pwd)
        `rm -rf '#{repository}'`
      end
    end

    def get_payload_request(request)
      request.body.rewind
      @payload_raw = request.body.read
      begin
        @payload = JSON.parse @payload_raw
      rescue StandardError => e
        raise 'Invalid JSON (#{e}): #{@payload_raw}'
      end
    end

    def authenticate_app
      @access_token = GITEE_PERSONAL_ACCESS_TOKEN
    end

    def verify_webhook_signature
      # their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
      # method, their_digest = their_signature_header.split('=')
      # our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, @payload_raw)
      # halt 401 unless their_digest == our_digest

      logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
      logger.debug "----    action #{@payload['action']}" unless @payload['action'].nil?
    end
  end

  # Finally some logic to let us run this server directly from the command line,
  # or with Rack. Don't worry too much about this code. But, for the curious:
  # $0 is the executed file
  # __FILE__ is the current file
  # If they are the same—that is, we are running this file directly, call the
  # Sinatra run method
  run! if $PROGRAM_NAME == __FILE__
end
