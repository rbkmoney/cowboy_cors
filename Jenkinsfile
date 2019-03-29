#!groovy
// -*- mode: groovy -*-

def finalHook = {
  runStage('store CT logs') {
    archive '_build/test/logs/'
  }
}

build('cowboy_cors', 'docker-host', finalHook) {
  checkoutRepo()
  loadBuildUtils()

  def pipeDefault
  def withWsCache
  runStage('load pipeline') {
    env.JENKINS_LIB = "build_utils/jenkins_lib"
    pipeDefault = load("${env.JENKINS_LIB}/pipeDefault.groovy")
    withWsCache = load("${env.JENKINS_LIB}/withWsCache.groovy")
  }

  pipeDefault() {

    if (!masterlikeBranch()) {

      runStage('compile') {
        withGithubPrivkey {
          sh 'make compile'
        }
      }

      runStage('lint') {
        sh 'make lint'
      }

      runStage('xref') {
        sh 'make xref'
      }

      runStage('dialyze') {
       withWsCache("_build/default/rebar3_21.1_plt") {
         sh 'make dialyze'
       }
      }

      runStage('test') {
        sh "make test"
      }

    }
  }
}
