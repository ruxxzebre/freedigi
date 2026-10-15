package main

import (
	"context"
	"embed"
	"fmt"
	"freedigi/internal/bridge"
	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
	"github.com/wailsapp/wails/v2/pkg/runtime"
	"os"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed assets/freedigi.png
var icon []byte
var build = "development"

type App struct {
	ctx     context.Context
	service *bridge.Service
}

func (a *App) startup(ctx context.Context)                  { a.ctx = ctx }
func (a *App) Status() bridge.State                         { return a.service.Status() }
func (a *App) Refresh() (bridge.State, error)               { return a.service.Refresh() }
func (a *App) Select(path string) (bridge.State, error)     { return a.service.Select(path) }
func (a *App) SetDryRun(enabled bool) (bridge.State, error) { return a.service.SetDryRun(enabled) }
func (a *App) Perform(action string, params map[string]any) (map[string]any, error) {
	return a.service.Perform(action, params)
}
func (a *App) Monitor(enabled bool) (bridge.State, error) { return a.service.Monitor(enabled) }
func (a *App) CopyReport() error                          { return runtime.ClipboardSetText(a.ctx, a.service.Report()) }
func (a *App) ExportReport() (string, error) {
	path, err := runtime.SaveFileDialog(a.ctx, runtime.SaveDialogOptions{Title: "Export FreeDigi diagnostics", DefaultFilename: "freedigi-diagnostics.txt"})
	if err != nil || path == "" {
		return path, err
	}
	return path, os.WriteFile(path, []byte(a.service.Report()), 0600)
}
func main() {
	a := &App{}
	a.service = bridge.New(bridge.HelperPath(), build, func(name string, data any) {
		if a.ctx != nil {
			runtime.EventsEmit(a.ctx, name, data)
		}
	})
	if len(os.Args) > 1 && os.Args[1] == "--self-test" {
		_, err := a.service.Refresh()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println(a.service.Report())
		return
	}
	err := wails.Run(&options.App{Title: "FreeDigi", Width: 1280, Height: 860, MinWidth: 960, MinHeight: 700,
		Linux:            &linux.Options{Icon: icon, ProgramName: "freedigi", WebviewGpuPolicy: linux.WebviewGpuPolicyNever},
		BackgroundColour: options.NewRGB(15, 19, 26), AssetServer: &assetserver.Options{Assets: assets},
		OnStartup: a.startup, OnShutdown: func(context.Context) { a.service.Close() }, Bind: []interface{}{a}})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
