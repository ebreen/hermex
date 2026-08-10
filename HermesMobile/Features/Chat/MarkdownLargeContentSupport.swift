//  MarkdownLargeContentSupport.swift
//  HermesMobile
//
//  Slice 0 registration scaffolding for issue #17 (large Markdown content).
//  This file intentionally defines no behavior yet: it is registered in the
//  app target before any test command names MarkdownLargeContentTests
//  (binding brief §8). Production types and behavior are introduced by
//  later #17 slices only.

import Foundation

/// Namespace placeholder for large-content Markdown support (issue #17).
///
/// Later #17 slices add the renderer-local policy seam and producer
/// metadata types named by the contract. Keep this file compile-safe:
/// it must never reference types that do not exist yet.
public enum MarkdownLargeContentSupport {}
