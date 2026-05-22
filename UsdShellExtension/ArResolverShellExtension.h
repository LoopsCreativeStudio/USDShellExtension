// USD Shell Extension - Copyright (C) 2025 Loops Creative Studio
// Licensed under the MIT License. See LICENSE.txt for details.

#pragma once

PXR_NAMESPACE_OPEN_SCOPE

class ArResolverShellExtension : public ArDefaultResolver
{
public:
	std::shared_ptr<ArAsset> _OpenAsset( const ArResolvedPath &resolvedPath ) const override;
};

PXR_NAMESPACE_CLOSE_SCOPE