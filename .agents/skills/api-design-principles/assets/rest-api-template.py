"""
Production-ready REST API template using FastAPI.
Includes pagination, filtering, error handling, and best practices.
"""

<<<<<<< HEAD
from datetime import datetime
from enum import Enum
from typing import Any

from fastapi import FastAPI, HTTPException, Path, Query, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, EmailStr, Field


app = FastAPI(title="API Template", version="1.0.0", docs_url="/api/docs")
=======
from fastapi import FastAPI, HTTPException, Query, Path, Depends, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, EmailStr, ConfigDict
from typing import Optional, List, Any
from datetime import datetime
from enum import Enum

app = FastAPI(
    title="API Template",
    version="1.0.0",
    docs_url="/api/docs"
)
>>>>>>> 2ecb89d (update)

# Security Middleware
# Trusted Host: Prevents HTTP Host Header attacks
app.add_middleware(
    TrustedHostMiddleware,
<<<<<<< HEAD
    allowed_hosts=["*"],  # TODO: Configure this in production, e.g. ["api.example.com"]
=======
    allowed_hosts=["*"] # TODO: Configure this in production, e.g. ["api.example.com"]
>>>>>>> 2ecb89d (update)
)

# CORS: Configures Cross-Origin Resource Sharing
app.add_middleware(
    CORSMiddleware,
<<<<<<< HEAD
    allow_origins=["*"],  # TODO: Update this with specific origins in production
    allow_credentials=False,  # TODO: Set to True if you need cookies/auth headers, but restrict origins
=======
    allow_origins=["*"], # TODO: Update this with specific origins in production
    allow_credentials=False, # TODO: Set to True if you need cookies/auth headers, but restrict origins
>>>>>>> 2ecb89d (update)
    allow_methods=["*"],
    allow_headers=["*"],
)

<<<<<<< HEAD

=======
>>>>>>> 2ecb89d (update)
# Models
class UserStatus(str, Enum):
    ACTIVE = "active"
    INACTIVE = "inactive"
    SUSPENDED = "suspended"

<<<<<<< HEAD

=======
>>>>>>> 2ecb89d (update)
class UserBase(BaseModel):
    email: EmailStr
    name: str = Field(..., min_length=1, max_length=100)
    status: UserStatus = UserStatus.ACTIVE

<<<<<<< HEAD

class UserCreate(UserBase):
    password: str = Field(..., min_length=8)


class UserUpdate(BaseModel):
    email: EmailStr | None = None
    name: str | None = Field(None, min_length=1, max_length=100)
    status: UserStatus | None = None

=======
class UserCreate(UserBase):
    password: str = Field(..., min_length=8)

class UserUpdate(BaseModel):
    email: Optional[EmailStr] = None
    name: Optional[str] = Field(None, min_length=1, max_length=100)
    status: Optional[UserStatus] = None
>>>>>>> 2ecb89d (update)

class User(UserBase):
    id: str
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)

<<<<<<< HEAD

=======
>>>>>>> 2ecb89d (update)
# Pagination
class PaginationParams(BaseModel):
    page: int = Field(1, ge=1)
    page_size: int = Field(20, ge=1, le=100)

<<<<<<< HEAD

class PaginatedResponse(BaseModel):
    items: list[Any]
=======
class PaginatedResponse(BaseModel):
    items: List[Any]
>>>>>>> 2ecb89d (update)
    total: int
    page: int
    page_size: int
    pages: int

<<<<<<< HEAD

# Error handling
class ErrorDetail(BaseModel):
    field: str | None = None
    message: str
    code: str


class ErrorResponse(BaseModel):
    error: str
    message: str
    details: list[ErrorDetail] | None = None

=======
# Error handling
class ErrorDetail(BaseModel):
    field: Optional[str] = None
    message: str
    code: str

class ErrorResponse(BaseModel):
    error: str
    message: str
    details: Optional[List[ErrorDetail]] = None
>>>>>>> 2ecb89d (update)

@app.exception_handler(HTTPException)
async def http_exception_handler(request, exc):
    return JSONResponse(
        status_code=exc.status_code,
        content=ErrorResponse(
            error=exc.__class__.__name__,
            message=exc.detail if isinstance(exc.detail, str) else exc.detail.get("message", "Error"),
<<<<<<< HEAD
            details=exc.detail.get("details") if isinstance(exc.detail, dict) else None,
        ).model_dump(),
    )


=======
            details=exc.detail.get("details") if isinstance(exc.detail, dict) else None
        ).model_dump()
    )

>>>>>>> 2ecb89d (update)
# Endpoints
@app.get("/api/users", response_model=PaginatedResponse, tags=["Users"])
async def list_users(
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
<<<<<<< HEAD
    status: UserStatus | None = Query(None),
    search: str | None = Query(None),
=======
    status: Optional[UserStatus] = Query(None),
    search: Optional[str] = Query(None)
>>>>>>> 2ecb89d (update)
):
    """List users with pagination and filtering."""
    # Mock implementation
    total = 100
    items = [
        User(
            id=str(i),
            email=f"user{i}@example.com",
            name=f"User {i}",
            status=UserStatus.ACTIVE,
            created_at=datetime.now(),
<<<<<<< HEAD
            updated_at=datetime.now(),
        ).model_dump()
        for i in range((page - 1) * page_size, min(page * page_size, total))
    ]

    return PaginatedResponse(
        items=items, total=total, page=page, page_size=page_size, pages=(total + page_size - 1) // page_size
    )


=======
            updated_at=datetime.now()
        ).model_dump()
        for i in range((page-1)*page_size, min(page*page_size, total))
    ]

    return PaginatedResponse(
        items=items,
        total=total,
        page=page,
        page_size=page_size,
        pages=(total + page_size - 1) // page_size
    )

>>>>>>> 2ecb89d (update)
@app.post("/api/users", response_model=User, status_code=status.HTTP_201_CREATED, tags=["Users"])
async def create_user(user: UserCreate):
    """Create a new user."""
    # Mock implementation
    return User(
        id="123",
        email=user.email,
        name=user.name,
        status=user.status,
        created_at=datetime.now(),
<<<<<<< HEAD
        updated_at=datetime.now(),
    )


=======
        updated_at=datetime.now()
    )

>>>>>>> 2ecb89d (update)
@app.get("/api/users/{user_id}", response_model=User, tags=["Users"])
async def get_user(user_id: str = Path(..., description="User ID")):
    """Get user by ID."""
    # Mock: Check if exists
    if user_id == "999":
        raise HTTPException(
<<<<<<< HEAD
            status_code=status.HTTP_404_NOT_FOUND, detail={"message": "User not found", "details": {"id": user_id}}
=======
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"message": "User not found", "details": {"id": user_id}}
>>>>>>> 2ecb89d (update)
        )

    return User(
        id=user_id,
        email="user@example.com",
        name="User Name",
        status=UserStatus.ACTIVE,
        created_at=datetime.now(),
<<<<<<< HEAD
        updated_at=datetime.now(),
    )


=======
        updated_at=datetime.now()
    )

>>>>>>> 2ecb89d (update)
@app.patch("/api/users/{user_id}", response_model=User, tags=["Users"])
async def update_user(user_id: str, update: UserUpdate):
    """Partially update user."""
    # Validate user exists
    existing = await get_user(user_id)

    # Apply updates
    update_data = update.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(existing, field, value)

    existing.updated_at = datetime.now()
    return existing

<<<<<<< HEAD

=======
>>>>>>> 2ecb89d (update)
@app.delete("/api/users/{user_id}", status_code=status.HTTP_204_NO_CONTENT, tags=["Users"])
async def delete_user(user_id: str):
    """Delete user."""
    await get_user(user_id)  # Verify exists
<<<<<<< HEAD


if __name__ == "__main__":
    import uvicorn

=======
    return None

if __name__ == "__main__":
    import uvicorn
>>>>>>> 2ecb89d (update)
    uvicorn.run(app, host="0.0.0.0", port=8000)
