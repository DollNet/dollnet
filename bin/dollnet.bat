@echo off
cd %~dp0/..
coffee main.coffee | bunyan -o short