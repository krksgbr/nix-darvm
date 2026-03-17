package rpc

import (
	"context"
	"net"

	pb "github.com/unbody/darvm/agent/gen"
	"google.golang.org/grpc"
)

type RPC struct {
	grpcServer *grpc.Server
	listener   net.Listener

	pb.UnimplementedAgentServer
}

func New(listener net.Listener) (*RPC, error) {
	rpc := &RPC{
		grpcServer: grpc.NewServer(),
		listener:   listener,
	}

	pb.RegisterAgentServer(rpc.grpcServer, rpc)

	return rpc, nil
}

func (rpc *RPC) Run(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		rpc.grpcServer.Stop()
	}()

	return rpc.grpcServer.Serve(rpc.listener)
}
