#!/bin/bash

BRANCH=$1

git push origin $BRANCH
pushd ~/koha.3.2.r_maint
git push origin $BRANCH
popd
