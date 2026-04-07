// darvm-agent: guest-side agent for DVM.
//
// Two components, selected via flags:
//
//	--run-rpc:    gRPC server on vsock port 6175 (Exec, Activate, Status, ResolveIP)
//	--run-bridge: nix daemon proxy (/tmp/nix-daemon.sock → vsock host:6174)
//
// Run both for full functionality. The RPC daemon also owns the TCP port forward
// listener so published host ports share the same liveness domain as the control plane.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/unbody/darvm/agent/internal/bridge"
	"github.com/unbody/darvm/agent/internal/rpc"
	"github.com/unbody/darvm/agent/internal/vsock"
	"golang.org/x/sync/errgroup"
)

const (
	rpcPort             = 6175
	portForwardPort     = 6177
	componentRetryDelay = time.Second
)

func main() {
	runRPC := flag.Bool("run-rpc", false, "run gRPC server on vsock port 6175")
	runBridge := flag.Bool("run-bridge", false, "run nix daemon bridge")

	flag.Parse()

	if !*runRPC && !*runBridge {
		log.Fatal("at least one of --run-rpc or --run-bridge must be specified")
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	group, ctx := errgroup.WithContext(ctx)

	if *runRPC {
		group.Go(func() error {
			for {
				if err := runRPCOnce(ctx); err != nil {
					return err
				}

				select {
				case <-time.After(componentRetryDelay):
					continue
				case <-ctx.Done():
					return ctx.Err()
				}
			}
		})
	}

	if *runBridge {
		group.Go(func() error {
			b := bridge.New()

			return b.Run(ctx)
		})
	}

	// Keep running until cancelled
	group.Go(func() error {
		<-ctx.Done()

		return ctx.Err()
	})

	if err := group.Wait(); err != nil && !errors.Is(err, context.Canceled) {
		log.Printf("darvm-agent exiting: %v", err)
		os.Exit(1)
	}
}

func runRPCOnce(ctx context.Context) error {
	log.Printf("initializing RPC server on vsock port %d...", rpcPort)

	rpcListener, err := vsock.Listen(rpcPort)
	if err != nil {
		log.Printf("RPC server failed to listen on AF_VSOCK port %d: %v", rpcPort, err)

		return nil // return nil to retry
	}

	defer func() {
		if closeErr := rpcListener.Close(); closeErr != nil {
			log.Printf("RPC listener close: %v", closeErr)
		}
	}()

	portForwardListener, err := vsock.Listen(portForwardPort)
	if err != nil {
		log.Printf("port forward listener failed to listen on AF_VSOCK port %d: %v", portForwardPort, err)

		return nil
	}

	defer func() {
		if closeErr := portForwardListener.Close(); closeErr != nil {
			log.Printf("port forward listener close: %v", closeErr)
		}
	}()

	rpcServer, err := rpc.New(rpcListener, portForwardListener)
	if err != nil {
		log.Printf("failed to initialize RPC server: %v", err)

		return nil
	}

	log.Printf(
		"RPC server running on AF_VSOCK port %d; port forwarding ready on AF_VSOCK port %d",
		rpcPort,
		portForwardPort,
	)

	if err := rpcServer.Run(ctx); err != nil {
		log.Printf("RPC server stopped: %v", err)

		return nil
	}

	return nil
}
