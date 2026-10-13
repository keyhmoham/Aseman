package vmm

import (
	"context"
	"testing"
)

func TestMediaRequestedRecognizesArtifactDelivery(t *testing.T) {
	for _, request := range []string{"Deliver the standalone index.html plus a ZIP containing every source file and a README as real downloadable attachments.", "Create files for the website", "Send a zip archive", "Generate images"} {
		if !MediaRequested(request, nil) {
			t.Errorf("missed explicit artifact request: %s", request)
		}
	}
	for _, request := range []string{"Explain the platform", "Share your opinion", "Analyze the existing files"} {
		if MediaRequested(request, nil) {
			t.Errorf("granted unsolicited delivery: %s", request)
		}
	}
}

func TestSoftwareDeliveryDoesNotAuthorizeImageGeneration(t *testing.T) {
	for _, request := range []string{"create a landing page about web3 for me and serve it", "Build a website", "Rebuild this landing page with nextjs and serve it", "Modify the dashboard", "Fix the application", "Implement a dashboard", "Develop an application", "Send\nthe HTML file"} {
		ctx := WithRequestIntent(context.Background(), request, nil)
		if !ArtifactIntent(ctx) {
			t.Errorf("requested artifact denied: %s", request)
		}
		if !MediaRequested(request, nil) && MediaIntent(ctx) {
			t.Errorf("software authorized images: %s", request)
		}
	}
	for _, request := range []string{"Review the existing website", "Tell me about an app"} {
		if ArtifactRequested(request, nil) {
			t.Errorf("unsolicited artifact: %s", request)
		}
	}
}
