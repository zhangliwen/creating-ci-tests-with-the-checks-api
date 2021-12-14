This is an example GitHub App that creates a CI server that runs CI tests using the GitHub [Checks API](https://developer.github.com/v3/checks/). You can follow the "[Creating CI tests with the Checks API](https://developer.github.com/apps/quickstart-guides/creating-ci-tests-with-the-checks-api/)" quickstart guide on developer.github.com to learn how to build the app code in `server.rb`.

This project handles check run and check suite webhook events and uses the Octokit.rb library to make REST API calls. The CI test runs [RuboCop](https://rubocop.readthedocs.io/en/latest/) on all Ruby code in a repository and reports errors using the Checks API. This example project consists of two different servers:\

1. Create a copy of the `.env-example` file called `.env`.
2. Add your GitHub App's private key, app ID, and webhook secret, app username, and app email to the `.env` file.

## Run the server

1. Run `ruby template_server.rb` or `ruby server.rb` on the command line.
1. View the default Sinatra app at `localhost:3000`.
test
test 2
特斯特
