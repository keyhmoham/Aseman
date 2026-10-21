// Package s3 implements the file storage port on AWS S3 (and S3-compatible
// endpoints such as MinIO).
package s3

import (
	"bytes"
	"context"
	"io"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/cfg"
	"github.com/aseman/aseman/plugins/adapters/filesystem/ports"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// Adapter is the S3 storage plugin.
type Adapter struct {
	base.Base
	client   *s3.Client
	uploader *manager.Uploader
	bucket   string
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "s3",
			Category:    api.CategoryFilesystem,
			Version:     "1.0.0",
			Description: "AWS S3 / S3-compatible object storage",
			Provides:    []string{"filesystem", "storage"},
			Log:         log,
		},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.Filesystem(deps.Config)
	return a.Open(ctx, c)
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error { return nil }

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return a.Close(ctx) }

// Name implements filesystem.FileStorage.
func (a *Adapter) Name() string { return "s3" }

// Open implements filesystem.FileStorage.
func (a *Adapter) Open(ctx context.Context, c filesystem.Config) error {
	if c.Bucket == "" {
		return errs.InvalidArgument("s3 storage requires config.bucket")
	}
	var opts []func(*awsconfig.LoadOptions) error
	if c.Endpoint != "" {
		opts = append(opts, awsconfig.WithEndpointResolverWithOptions(
			aws.EndpointResolverWithOptionsFunc(func(service, region string, options ...any) (aws.Endpoint, error) {
				return aws.Endpoint{URL: c.Endpoint, HostnameImmutable: true}, nil
			})))
	}
	if c.Region != "" {
		opts = append(opts, awsconfig.WithRegion(c.Region))
	}
	// Keys for this store alone (options), else the AWS environment's.
	if id, secret := c.Options["access_key_id"], c.Options["secret_access_key"]; id != "" && secret != "" {
		opts = append(opts, awsconfig.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(id, secret, "")))
	}
	cfgAWS, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "load aws config")
	}
	a.client = s3.NewFromConfig(cfgAWS, func(o *s3.Options) {
		if c.Endpoint != "" {
			// S3-compatible stores (Cloudflare R2, MinIO) address the bucket in the path.
			o.UsePathStyle = true
		}
		// Only send and check the checksums an operation requires: stores that are
		// not AWS reject the newer default trailing checksums.
		o.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
		o.ResponseChecksumValidation = aws.ResponseChecksumValidationWhenRequired
	})
	a.uploader = manager.NewUploader(a.client)
	a.bucket = c.Bucket
	return nil
}

// Close implements filesystem.FileStorage.
func (a *Adapter) Close(ctx context.Context) error { return nil }

// Health implements filesystem.FileStorage.
func (a *Adapter) Health(ctx context.Context) filesystem.Health {
	if a.client == nil {
		return filesystem.Health{OK: false, Message: "s3 not open"}
	}
	_, err := a.client.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: &a.bucket, MaxKeys: aws.Int32(1)})
	if err != nil {
		return filesystem.Health{OK: false, Message: err.Error()}
	}
	return filesystem.Health{OK: true, Message: "s3 healthy"}
}

// Put implements filesystem.FileStorage.
func (a *Adapter) Put(ctx context.Context, key string, r io.Reader, size int64, contentType string) error {
	if size <= 0 {
		b, err := io.ReadAll(r)
		if err != nil {
			return errs.Wrap(errs.CodePlugin, err, "read body")
		}
		r = bytes.NewReader(b)
		size = int64(len(b))
	}
	_, err := a.uploader.Upload(ctx, &s3.PutObjectInput{
		Bucket:      &a.bucket,
		Key:         &key,
		Body:        r,
		ContentType: aws.String(contentType),
	})
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "s3 put")
	}
	return nil
}

// Get implements filesystem.FileStorage.
func (a *Adapter) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	out, err := a.client.GetObject(ctx, &s3.GetObjectInput{Bucket: &a.bucket, Key: &key})
	if err != nil {
		if isNotFound(err) {
			return nil, errs.NotFound("object " + key)
		}
		return nil, errs.Wrap(errs.CodePlugin, err, "s3 get")
	}
	return out.Body, nil
}

// Delete implements filesystem.FileStorage.
func (a *Adapter) Delete(ctx context.Context, key string) error {
	if _, err := a.client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &a.bucket, Key: &key}); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "s3 delete")
	}
	return nil
}

// Stat implements filesystem.FileStorage.
func (a *Adapter) Stat(ctx context.Context, key string) (filesystem.ObjectInfo, error) {
	out, err := a.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: &a.bucket, Key: &key})
	if err != nil {
		if isNotFound(err) {
			return filesystem.ObjectInfo{}, errs.NotFound("object " + key)
		}
		return filesystem.ObjectInfo{}, errs.Wrap(errs.CodePlugin, err, "s3 head")
	}
	mod := time.Time{}
	if out.LastModified != nil {
		mod = *out.LastModified
	}
	ct := ""
	if out.ContentType != nil {
		ct = *out.ContentType
	}
	return filesystem.ObjectInfo{Key: key, Size: aws.ToInt64(out.ContentLength), ContentType: ct, Modified: mod}, nil
}

// Exists implements filesystem.FileStorage.
func (a *Adapter) Exists(ctx context.Context, key string) (bool, error) {
	_, err := a.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: &a.bucket, Key: &key})
	if err != nil {
		if isNotFound(err) {
			return false, nil
		}
		return false, errs.Wrap(errs.CodePlugin, err, "s3 head")
	}
	return true, nil
}

// List implements filesystem.FileStorage.
func (a *Adapter) List(ctx context.Context, prefix string) ([]filesystem.ObjectInfo, error) {
	var out []filesystem.ObjectInfo
	paginator := s3.NewListObjectsV2Paginator(a.client, &s3.ListObjectsV2Input{
		Bucket: &a.bucket,
		Prefix: aws.String(prefix),
	})
	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return nil, errs.Wrap(errs.CodePlugin, err, "s3 list")
		}
		for _, obj := range page.Contents {
			mod := time.Time{}
			if obj.LastModified != nil {
				mod = *obj.LastModified
			}
			out = append(out, filesystem.ObjectInfo{
				Key:      aws.ToString(obj.Key),
				Size:     aws.ToInt64(obj.Size),
				Modified: mod,
			})
		}
	}
	return out, nil
}

func isNotFound(err error) bool {
	return isAWSNotFound(err)
}

func isAWSNotFound(err error) bool {
	if err == nil {
		return false
	}
	return contains(err.Error(), "NotFound") || contains(err.Error(), "NoSuchKey") ||
		contains(err.Error(), "404")
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (indexOf(s, sub) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
