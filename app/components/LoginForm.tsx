"use client";

import React, { useState } from "react";
import { useRouter } from "next/navigation";
import FormInput from "./forms/FormInput";
import ErrorMessage from "./ui/ErrorMessage";
import LoadingSpinner from "./ui/LoadingSpinner";
import ThemeToggle from "./ui/ThemeToggle";

export default function LoginForm() {
  const router = useRouter();
  const [formData, setFormData] = useState({
    email: "",
    password: "",
  });
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const { name, value } = e.target;
    setFormData({
      ...formData,
      [name]: value,
    });
    if (error) setError("");
  };

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setLoading(true);
    setError("");

    try {
      const response = await fetch("/api/login", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(formData),
        credentials: "include",
      });

      const data = await response.json();

      if (!response.ok) {
        throw new Error(data.error || "Login failed");
      }

      // Cookie is set by the server; just navigate.
      router.push("/dashboard");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Unknown error");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50 dark:bg-gray-900 transition-colors px-4 py-8 relative">
      <div className="absolute top-4 right-4">
        <ThemeToggle variant="light" />
      </div>
      <div className="max-w-md w-full">
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow-lg border border-gray-200 dark:border-gray-700 p-6 sm:p-8 transition-colors">
          <div className="text-center mb-8">
            <h1 className="text-3xl font-bold text-gray-900 dark:text-gray-100 mb-2">
              License Administration
            </h1>
            <p className="text-gray-600 dark:text-gray-400 text-sm">
              Sign in to manage your licenses
            </p>
          </div>

          {error && (
            <div className="mb-6">
              <ErrorMessage
                message={error}
                onDismiss={() => setError("")}
              />
            </div>
          )}

          <form onSubmit={handleSubmit}>
            <FormInput
              label="Email Address"
              name="email"
              type="email"
              value={formData.email}
              onChange={handleChange}
              required
              placeholder="Enter your email"
              disabled={loading}
              className="mb-4"
            />

            <FormInput
              label="Password"
              name="password"
              type="password"
              value={formData.password}
              onChange={handleChange}
              required
              placeholder="Enter your password"
              disabled={loading}
              className="mb-6"
            />

            <button
              type="submit"
              disabled={loading}
              className="w-full bg-blue-600 dark:bg-blue-700 text-white font-semibold py-3 px-4 rounded-md hover:bg-blue-700 dark:hover:bg-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:focus:ring-offset-gray-800 transition-colors disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center space-x-2"
            >
              {loading && <LoadingSpinner size="sm" />}
              <span>{loading ? "Signing in..." : "Sign In"}</span>
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}

