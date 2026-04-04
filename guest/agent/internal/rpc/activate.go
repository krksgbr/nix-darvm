package rpc

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"

	pb "github.com/unbody/darvm/agent/gen"
)

func (rpc *RPC) Activate(ctx context.Context, req *pb.ActivateRequest) (*pb.ActivateResponse, error) {
	path := req.GetClosurePath()
	if !strings.HasPrefix(path, "/nix/store/") {
		return &pb.ActivateResponse{
			Success: false,
			Error:   "invalid path: must start with /nix/store/",
		}, nil
	}

	// Update profile symlink BEFORE activation. darwin-rebuild reads the
	// current profile to diff services and resolve primaryUser. If the old
	// profile references a user that was renamed, activation fails.
	if req.GetUpdateProfile() {
		profilePath := "/nix/var/nix/profiles/system"
		log.Printf("activate: updating profile symlink %s -> %s", profilePath, path)

		cmd := exec.CommandContext(ctx, "sudo", "ln", "-sfn", path, profilePath)
		if err := cmd.Run(); err != nil {
			log.Printf("activate: profile symlink failed: %v", err)

			return &pb.ActivateResponse{
				Success: false,
				Error:   fmt.Sprintf("profile symlink failed: %v", err),
			}, nil
		}
	}

	activateScript := path + "/activate"
	log.Printf("activate: running %s", activateScript)

	cmd := exec.CommandContext(ctx, "sudo", activateScript)
	cmd.Stdout = os.Stdout

	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Printf("activate: failed: %v", err)

		return &pb.ActivateResponse{
			Success: false,
			Error:   fmt.Sprintf("activation failed: %v", err),
		}, nil
	}

	log.Printf("activate: succeeded")

	return &pb.ActivateResponse{
		Success:       true,
		ActivatedPath: path,
	}, nil
}
