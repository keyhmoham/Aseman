package apihttp

import (
	"encoding/json"
	"regexp"
	"strings"
)

// A preview is served under /v1/proxy/{id}/, but the app was built for the
// site root: its links, forms and client-side router (Next.js, React Router…)
// navigate to "/about", which leaves the proxy and lands on the Tradera app
// that shares the origin. The gateway keeps the page inside its prefix in two
// ways: root-relative attributes in the served HTML are prefixed, and a small
// script, injected before the app's own, prefixes the URLs the page navigates
// to or requests at runtime.

// proxyShim is the injected script; %s is the JSON-encoded prefix without its
// trailing slash. It leaves relative, already-prefixed and cross-origin URLs
// untouched, so running it on an app built for the prefix changes nothing.
const proxyShim = `<script data-tradera-proxy>(function(){
var P=%s;if(window.__traderaProxy)return;window.__traderaProxy=P;
var O=location.origin,H=location.host;
function inside(p){return p===P||p.indexOf(P+"/")===0||p.indexOf("/v1/proxy/")===0;}
function fix(u){
if(typeof u!=="string"){if(typeof URL!=="undefined"&&u instanceof URL){var f=fix(u.href);return f===u.href?u:new URL(f);}return u;}
if(u.charAt(0)==="/"&&u.charAt(1)!=="/"&&u.charAt(1)!=="\\"){return inside(u.split(/[?#]/)[0])?u:P+u;}
if(!/^(https?|wss?):\/\//i.test(u))return u;
try{var x=new URL(u);}catch(e){return u;}
if(x.host!==H||inside(x.pathname))return u;
if(/^https?:$/.test(x.protocol)&&x.origin!==O)return u;
x.pathname=P+x.pathname;return x.href;}
window.__traderaProxyFix=fix;
var h=window.history;
["pushState","replaceState"].forEach(function(m){var o=h[m];if(!o)return;h[m]=function(s,t,u){return arguments.length>2&&u!=null?o.call(this,s,t,fix(u)):o.apply(this,arguments);};});
if(window.fetch){var of=window.fetch;window.fetch=function(i,n){
if(typeof Request!=="undefined"&&i instanceof Request){var f=fix(i.url);if(f!==i.url)i=new Request(f,i);}else{i=fix(i);}
return of.call(this,i,n);};}
if(window.XMLHttpRequest){var oo=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){var a=Array.prototype.slice.call(arguments);a[1]=fix(u);return oo.apply(this,a);};}
["EventSource","WebSocket"].forEach(function(k){var C=window[k];if(!C)return;
var W=function(u,p){return arguments.length>1?new C(fix(u),p):new C(fix(u));};
W.prototype=C.prototype;["CONNECTING","OPEN","CLOSING","CLOSED"].forEach(function(s){if(s in C)W[s]=C[s];});window[k]=W;});
if(window.open){var ow=window.open;window.open=function(u){var a=Array.prototype.slice.call(arguments);if(a.length)a[0]=fix(u);return ow.apply(this,a);};}
if(navigator.sendBeacon){var ob=navigator.sendBeacon;navigator.sendBeacon=function(u,d){return ob.call(navigator,fix(u),d);};}
var A={href:1,src:1,action:1,formaction:1,poster:1,data:1};
function fixEl(el){if(!el||el.nodeType!==1)return;
for(var n in A){var v=el.getAttribute(n);if(v){var f=fix(v);if(f!==v)el.setAttribute(n,f);}}}
function fixTree(el){if(!el||el.nodeType!==1)return;fixEl(el);
if(el.querySelectorAll){var l=el.querySelectorAll("[href],[src],[action],[formaction],[poster],[data]");for(var i=0;i<l.length;i++)fixEl(l[i]);}}
if(window.MutationObserver){new MutationObserver(function(rs){rs.forEach(function(r){
if(r.type==="attributes")fixEl(r.target);else for(var i=0;i<r.addedNodes.length;i++)fixTree(r.addedNodes[i]);});})
.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:Object.keys(A)});}
document.addEventListener("click",function(e){var t=e.target;while(t&&t.nodeType===1&&!(t.tagName==="A"||t.tagName==="AREA"))t=t.parentNode;if(t&&t.nodeType===1)fixEl(t);},true);
document.addEventListener("submit",function(e){fixEl(e.target);if(e.submitter)fixEl(e.submitter);},true);
})();</script>`

// injectProxyShim adds the navigation script to an HTML page, as early as
// possible so it runs before the app's own scripts.
func injectProxyShim(body []byte, ctype, prefix string) []byte {
	if !strings.Contains(strings.ToLower(ctype), "text/html") {
		return body
	}
	if strings.Contains(string(body), "data-tradera-proxy") {
		return body
	}
	quoted, _ := json.Marshal(strings.TrimRight(prefix, "/"))
	// "</" inside a JSON string must not end the script element.
	shim := strings.Replace(proxyShim, "%s", strings.ReplaceAll(string(quoted), "</", `<\/`), 1)
	for _, open := range []*regexp.Regexp{headOpen, htmlOpen} {
		if loc := open.FindIndex(body); loc != nil {
			return splice(body, loc[1], shim)
		}
	}
	// No <head> or <html>: after a leading doctype, else at the very start.
	if loc := doctype.FindIndex(body); loc != nil {
		return splice(body, loc[1], shim)
	}
	return splice(body, 0, shim)
}

var (
	headOpen = regexp.MustCompile(`(?i)<head(\s[^>]*)?>`)
	htmlOpen = regexp.MustCompile(`(?i)<html(\s[^>]*)?>`)
	doctype  = regexp.MustCompile(`(?i)^\s*<!doctype[^>]*>`)
	// rootAttr matches an HTML attribute whose value is a root-relative URL
	// (href="/about", action='/login', src=/logo.png), not a protocol-relative
	// one (//cdn…). The value is group 3; group 4 is the character ending it.
	rootAttr = regexp.MustCompile(`(?i)(\b(?:href|src|action|formaction|poster)\s*=\s*)(["']?)(/(?:[^/\\"'\s>][^"'\s>]*)?)(["'\s>])`)
)

func splice(body []byte, at int, s string) []byte {
	out := make([]byte, 0, len(body)+len(s))
	out = append(out, body[:at]...)
	out = append(out, s...)
	return append(out, body[at:]...)
}

// rewriteProxyLinks prefixes root-relative link, form and media attributes of
// served HTML so plain navigation (no script) stays inside the proxy. Values
// already under a proxy prefix are left as they are.
func rewriteProxyLinks(body []byte, ctype, prefix string) []byte {
	if !strings.Contains(strings.ToLower(ctype), "text/html") {
		return body
	}
	base := strings.TrimRight(prefix, "/")
	return rootAttr.ReplaceAllFunc(body, func(m []byte) []byte {
		sub := rootAttr.FindSubmatchIndex(m)
		value := string(m[sub[6]:sub[7]])
		if value == base || strings.HasPrefix(value, base+"/") || strings.HasPrefix(value, "/v1/proxy/") {
			return m
		}
		out := make([]byte, 0, len(m)+len(base))
		out = append(out, m[:sub[6]]...)
		out = append(out, base...)
		return append(out, m[sub[6]:]...)
	})
}
