pipeline {

  options {
    buildDiscarder(logRotator(numToKeepStr: '5'))
  }

  environment {
        PATH="/opt/anaconda/bin:/opt/snap/bin:/opt/anaconda/bin:/opt/anaconda/bin:/usr/lib64/qt-3.3/bin:/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/home/fbrito/bin"
  }

  agent {
    node {
      label 'ci-community-docker'
    }
  }

  stages {

    stage('Package & Dockerize') {
      steps {
        withMaven( maven: 'apache-maven-3.0.5' ) {
            sh 'mvn -B deploy'
        }
      }
    }
  }
}
